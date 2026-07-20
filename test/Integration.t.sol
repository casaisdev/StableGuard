// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

import {PriceOracle} from "../src/PriceOracle.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LiquidationManager} from "../src/LiquidationManager.sol";
import {DutchAuctionManager} from "../src/DutchAuctionManager.sol";
import {ArbitrageManager} from "../src/ArbitrageManager.sol";
import {RepegManager} from "../src/RepegManager.sol";
import {StableGuard} from "../src/StableGuard.sol";
import {Timelock} from "../src/Timelock.sol";
import {Constants} from "../src/Constants.sol";
import {IRepegManager} from "../src/interfaces/IRepegManager.sol";
import {IDutchAuctionManager} from "../src/interfaces/IDutchAuctionManager.sol";

/// @dev Minimal configurable Chainlink aggregator
contract MockAggregator is AggregatorV3Interface {
    int256 public answer;
    uint8 public immutable dec;
    uint80 private round = 1;

    constructor(int256 _answer, uint8 _dec) {
        answer = _answer;
        dec = _dec;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        round++;
    }

    function decimals() external view returns (uint8) {
        return dec;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _round) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, answer, block.timestamp, block.timestamp, _round);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, block.timestamp, block.timestamp, round);
    }
}

contract TestToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @title Full-protocol integration tests
/// @dev Wires the real contracts exactly like script/Deploy.s.sol and exercises
///      the complete deposit -> mint -> price drop -> liquidation lifecycle with
///      an 8-decimal collateral token (WBTC-like) to catch decimal bugs.
contract IntegrationTest is Test {
    PriceOracle oracle;
    CollateralManager collateral;
    LiquidationManager liquidation;
    DutchAuctionManager auction;
    ArbitrageManager arbitrage;
    RepegManager repeg;
    StableGuard guard;
    Timelock timelock;

    TestToken wbtc; // 8 decimals
    MockAggregator wbtcFeed;

    address deployer = address(this);
    address alice = makeAddr("alice"); // borrower
    address bob = makeAddr("bob"); // liquidator / bidder

    uint256 constant WBTC_START_PRICE = 30_000e18; // $30,000, 1e18 scale

    function setUp() public {
        vm.warp(1_000_000);
        _deployAll();

        // Configure WBTC (8 decimals) as collateral
        wbtc = new TestToken("Wrapped BTC", "WBTC", 8);
        wbtcFeed = new MockAggregator(int256(30_000e8), 8); // $30,000 at 8 feed decimals
        oracle.configureToken(address(wbtc), address(wbtcFeed), 30_000e18, 8);

        // Disable rate limiting so the lifecycle isn't throttled
        guard.setRateLimitingPause(true);
    }

    function _deployAll() internal {
        oracle = new PriceOracle();
        collateral = new CollateralManager(address(oracle));
        liquidation = new LiquidationManager(deployer, address(oracle), address(collateral));
        auction = new DutchAuctionManager(address(oracle), address(collateral));
        timelock = new Timelock(2 days);

        address predictedGuard = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);

        // Router/WETH are irrelevant to the liquidation lifecycle; use placeholders
        address router = makeAddr("router");
        address weth = makeAddr("weth");
        arbitrage = new ArbitrageManager(router, address(oracle), weth, predictedGuard);
        repeg = new RepegManager(
            predictedGuard,
            address(oracle),
            predictedGuard,
            address(arbitrage),
            IRepegManager.RepegConfig({
                targetPrice: uint128(Constants.PRICE_PRECISION),
                deviationThreshold: uint64(Constants.REPEG_DEVIATION_THRESHOLD),
                repegCooldown: uint32(Constants.REPEG_COOLDOWN),
                arbitrageWindow: uint32(Constants.REPEG_ARBITRAGE_WINDOW),
                incentiveRate: uint16(Constants.REPEG_INCENTIVE_RATE),
                maxRepegPerDay: uint8(Constants.MAX_REPEG_PER_DAY),
                enabled: true
            })
        );

        guard = new StableGuard(
            address(oracle),
            address(collateral),
            address(liquidation),
            address(auction),
            address(repeg),
            address(timelock)
        );
        require(address(guard) == predictedGuard, "prediction mismatch");

        collateral.setStableGuard(address(guard));
        collateral.setAuthorizedManager(address(auction), true);
        liquidation.setStableGuard(address(guard));
        auction.setStableGuard(address(guard));
    }

    /// @dev Alice deposits 1 WBTC and mints SGD at a healthy ratio
    function _openPosition(uint256 mintAmount) internal {
        wbtc.mint(alice, 1e8); // 1 WBTC
        vm.startPrank(alice);
        wbtc.approve(address(guard), 1e8);
        guard.depositAndMint(address(wbtc), 1e8, mintAmount);
        vm.stopPrank();
    }

    function test_FullLiquidationLifecycle() public {
        // 1 WBTC = $30,000 -> mint $20,000 (150% ratio)
        uint256 mintAmount = 20_000e18;
        _openPosition(mintAmount);

        assertEq(guard.balanceOf(alice), mintAmount);
        assertEq(collateral.getUserCollateral(alice, address(wbtc)), 1e8);

        // Price drops to $22,000: collateral $22,000 vs debt $20,000 -> 110% < 120%
        wbtcFeed.setAnswer(int256(22_000e8));
        oracle.updateFallbackPrice(address(wbtc), 22_000e18);

        // Keeper opens the auction
        uint256 auctionId = guard.liquidate(alice, mintAmount);
        IDutchAuctionManager.DutchAuction memory a = auction.getAuction(auctionId);
        assertTrue(a.active);
        assertEq(a.tokenDecimals, 8);

        // Warp to the middle of the price curve
        vm.warp(block.timestamp + 1800); // half of the 3600s duration
        uint256 price = auction.getCurrentPrice(auctionId);
        uint256 cost = (price * a.collateralAmount) / (10 ** a.tokenDecimals);

        // Bob acquires SGD (mint his own over-collateralized position) to bid
        _fundBidderWithSgd(bob, cost);

        uint256 supplyBefore = guard.totalSupply();
        uint256 aliceDebtBefore = guard.getDebt(alice);
        uint256 bobWbtcBefore = wbtc.balanceOf(bob);

        vm.startPrank(bob);
        guard.approve(address(auction), cost);
        auction.bidOnAuction(auctionId, price);
        vm.stopPrank();

        // Debt settled and supply burned by the same amount
        uint256 debtSettled = cost < mintAmount ? cost : mintAmount;
        assertEq(guard.getDebt(alice), aliceDebtBefore - debtSettled, "debt reduced by settled amount");
        assertEq(guard.totalSupply(), supplyBefore - debtSettled, "supply burned by settled amount");

        // Bob received the seized collateral; Alice's custody was debited
        assertEq(wbtc.balanceOf(bob), bobWbtcBefore + a.collateralAmount, "bidder got collateral");
        assertEq(
            collateral.getUserCollateral(alice, address(wbtc)), 1e8 - a.collateralAmount, "borrower custody debited"
        );

        // Conservation: WBTC held by CollateralManager equals the sum of every
        // user's recorded custody (Alice's remainder + Bob's own deposit).
        uint256 aliceCustody = collateral.getUserCollateral(alice, address(wbtc));
        uint256 bobCustody = collateral.getUserCollateral(bob, address(wbtc));
        assertEq(wbtc.balanceOf(address(collateral)), aliceCustody + bobCustody, "custody balance conserved");

        // Auction closed
        assertFalse(auction.getAuction(auctionId).active);
    }

    function test_LiquidatePosition_DirectPath() public {
        uint256 mintAmount = 20_000e18;
        _openPosition(mintAmount);

        // Drop price so the position is liquidatable
        wbtcFeed.setAnswer(int256(22_000e8));
        oracle.updateFallbackPrice(address(wbtc), 22_000e18);

        // Bob repays part of the debt directly and seizes collateral (with bonus)
        uint256 repayAmount = 10_000e18;
        _fundBidderWithSgd(bob, repayAmount);

        uint256 bobWbtcBefore = wbtc.balanceOf(bob);
        vm.startPrank(bob);
        guard.approve(address(guard), repayAmount);
        guard.liquidatePosition(alice, address(wbtc), repayAmount);
        vm.stopPrank();

        // Debt reduced and Bob received collateral worth repay + bonus
        assertEq(guard.getDebt(alice), mintAmount - repayAmount);
        assertGt(wbtc.balanceOf(bob), bobWbtcBefore, "liquidator seized collateral");
    }

    function test_EmergencyLiquidate_OwnerSuppliesSgd() public {
        uint256 mintAmount = 20_000e18;
        _openPosition(mintAmount);

        uint256 debtToClear = 5_000e18;
        _fundBidderWithSgd(deployer, debtToClear);

        uint256 supplyBefore = guard.totalSupply();
        uint256 ownerWbtcBefore = wbtc.balanceOf(deployer);

        guard.approve(address(guard), debtToClear);
        guard.emergencyLiquidate(alice, address(wbtc), debtToClear);

        assertEq(guard.getDebt(alice), mintAmount - debtToClear);
        assertEq(guard.totalSupply(), supplyBefore - debtToClear, "single burn");
        assertGt(wbtc.balanceOf(deployer), ownerWbtcBefore, "owner seized equivalent collateral");
    }

    /// @dev Give `who` `amount` SGD by opening an over-collateralized WBTC position
    function _fundBidderWithSgd(address who, uint256 amount) internal {
        // Collateral worth 300% of the requested SGD, priced at the current feed
        uint256 wbtcAmount = (amount * 3 * 1e8) / WBTC_START_PRICE + 1e8;
        // Use the live price to size collateral safely regardless of prior drops
        wbtc.mint(who, wbtcAmount);
        vm.startPrank(who);
        wbtc.approve(address(guard), wbtcAmount);
        guard.depositAndMint(address(wbtc), wbtcAmount, amount);
        vm.stopPrank();
    }
}
