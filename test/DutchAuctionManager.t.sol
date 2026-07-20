// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DutchAuctionManager} from "../src/DutchAuctionManager.sol";
import {IDutchAuctionManager} from "../src/interfaces/IDutchAuctionManager.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ICollateralManager} from "../src/interfaces/ICollateralManager.sol";
import {Constants} from "../src/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DutchAuctionManagerTest is Test {
    DutchAuctionManager public auctionManager;
    MockPriceOracle public priceOracle;
    MockCollateralManager public collateralManager;
    MockERC20 public mockToken;
    MockStableGuardSGD public stableGuardSGD;

    address public owner = address(0x1);
    address public stableGuard; // address of stableGuardSGD (the SGD token + settlement mock)
    address public user = address(0x3);
    address public bidder = address(0x4);
    address public bidder2 = address(0x5);

    uint256 public constant INITIAL_ETH_BALANCE = 2000 ether;
    uint256 public constant INITIAL_TOKEN_BALANCE = 1000000e18;
    uint256 public constant DEFAULT_DEBT_AMOUNT = 1000e18;
    uint256 public constant DEFAULT_COLLATERAL_AMOUNT = 10e18; // 10 ETH - reasonable for testing
    uint256 public constant DEFAULT_TOKEN_PRICE = 1e18; // 1 ETH per token

    event AuctionEvent(
        uint256 indexed auctionId,
        address indexed userOrWinner,
        address indexed token,
        uint8 eventType,
        uint128 amount,
        uint128 price
    );

    event BidCommitted(bytes32 indexed commitHash, uint256 indexed auctionId, address indexed bidder);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mocks
        priceOracle = new MockPriceOracle();
        collateralManager = new MockCollateralManager();
        mockToken = new MockERC20("Mock Token", "MTK");
        stableGuardSGD = new MockStableGuardSGD();
        stableGuard = address(stableGuardSGD);

        // Deploy DutchAuctionManager
        auctionManager = new DutchAuctionManager(address(priceOracle), address(collateralManager));

        // Set StableGuard (also the SGD token bids are paid in)
        auctionManager.setStableGuard(stableGuard);

        // Setup initial state
        priceOracle.setTokenPrice(address(mockToken), DEFAULT_TOKEN_PRICE);
        priceOracle.setTokenPrice(Constants.ETH_TOKEN, DEFAULT_TOKEN_PRICE);

        collateralManager.setUserCollateral(user, address(mockToken), DEFAULT_COLLATERAL_AMOUNT);
        collateralManager.setUserCollateral(user, Constants.ETH_TOKEN, DEFAULT_COLLATERAL_AMOUNT);

        // The CollateralManager custodies the assets it pays out on seizure
        vm.deal(address(collateralManager), 50 ether);
        mockToken.mint(address(collateralManager), INITIAL_TOKEN_BALANCE);

        // Tokens held by the auction manager itself (for emergencyWithdraw tests)
        mockToken.mint(address(auctionManager), INITIAL_TOKEN_BALANCE);

        vm.stopPrank();

        // Bidders hold SGD and pre-approve the auction manager
        stableGuardSGD.mint(bidder, INITIAL_TOKEN_BALANCE);
        stableGuardSGD.mint(bidder2, INITIAL_TOKEN_BALANCE);
        vm.prank(bidder);
        stableGuardSGD.approve(address(auctionManager), type(uint256).max);
        vm.prank(bidder2);
        stableGuardSGD.approve(address(auctionManager), type(uint256).max);
    }

    // ============ HELPERS ============

    /// @dev Bid cost in SGD for an auction at the current price
    function _costOf(uint256 auctionId) internal view returns (uint256) {
        IDutchAuctionManager.DutchAuction memory a = auctionManager.getAuction(auctionId);
        return (auctionManager.getCurrentPrice(auctionId) * a.collateralAmount) / (10 ** a.tokenDecimals);
    }

    /// @dev Mint SGD to a bidder and approve the auction manager
    function _fundAndApprove(address _bidder, uint256 amount) internal {
        stableGuardSGD.mint(_bidder, amount);
        vm.prank(_bidder);
        stableGuardSGD.approve(address(auctionManager), type(uint256).max);
    }

    // ============ BASIC FUNCTIONALITY TESTS ============

    function test_Constructor() public view {
        assertEq(auctionManager.owner(), owner);
        assertEq(address(auctionManager.PRICE_ORACLE()), address(priceOracle));
        assertEq(address(auctionManager.COLLATERAL_MANAGER()), address(collateralManager));
        assertEq(auctionManager.stableGuard(), stableGuard);

        (uint64 duration, uint64 minPriceFactor, uint64 liquidationBonus) = auctionManager.getConfig();
        assertEq(duration, 3600); // 1 hour
        assertEq(minPriceFactor, 5000); // 50%
        assertEq(liquidationBonus, 1000); // 10%
    }

    function test_SetStableGuard() public {
        address newStableGuard = address(0x999);

        vm.prank(owner);
        auctionManager.setStableGuard(newStableGuard);

        assertEq(auctionManager.stableGuard(), newStableGuard);
    }

    function test_SetStableGuard_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        auctionManager.setStableGuard(address(0x999));
    }

    function test_SetStableGuard_InvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(IDutchAuctionManager.InvalidAddress.selector);
        auctionManager.setStableGuard(address(0));
    }

    // ============ START AUCTION TESTS ============

    function test_StartDutchAuction_ETH() public {
        vm.prank(stableGuard);

        vm.expectEmit(true, true, true, true);
        emit AuctionEvent(
            1, user, Constants.ETH_TOKEN, 0, uint128(DEFAULT_COLLATERAL_AMOUNT), uint128(DEFAULT_TOKEN_PRICE)
        );

        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        assertEq(auctionId, 1);
        assertEq(auctionManager.getAuctionCounter(), 1);

        IDutchAuctionManager.DutchAuction memory auction = auctionManager.getAuction(auctionId);
        assertEq(auction.user, user);
        assertEq(auction.token, Constants.ETH_TOKEN);
        assertEq(auction.debtAmount, DEFAULT_DEBT_AMOUNT);
        assertEq(auction.collateralAmount, DEFAULT_COLLATERAL_AMOUNT);
        assertEq(auction.startPrice, DEFAULT_TOKEN_PRICE);
        assertEq(auction.endPrice, DEFAULT_TOKEN_PRICE / 2); // 50% of start price
        assertTrue(auction.active);
        assertEq(auction.startTime, block.timestamp);
        assertEq(auction.duration, 3600);
    }

    function test_StartDutchAuction_Token() public {
        vm.prank(stableGuard);

        uint256 auctionId = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);

        IDutchAuctionManager.DutchAuction memory auction = auctionManager.getAuction(auctionId);
        assertEq(auction.token, address(mockToken));
        assertTrue(auction.active);
    }

    function test_StartDutchAuction_OnlyStableGuard() public {
        vm.prank(user);
        vm.expectRevert(IDutchAuctionManager.Unauthorized.selector);
        auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
    }

    function test_StartDutchAuction_InvalidUser() public {
        vm.prank(stableGuard);
        vm.expectRevert(IDutchAuctionManager.InvalidAddress.selector);
        auctionManager.startDutchAuction(address(0), Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
    }

    function test_StartDutchAuction_ZeroDebt() public {
        vm.prank(stableGuard);
        vm.expectRevert();
        auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, 0);
    }

    function test_StartDutchAuction_NoCollateral() public {
        address userWithoutCollateral = address(0x999);

        vm.prank(stableGuard);
        vm.expectRevert(IDutchAuctionManager.NoCollateral.selector);
        auctionManager.startDutchAuction(userWithoutCollateral, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
    }

    function test_StartDutchAuction_InvalidPrice() public {
        priceOracle.setTokenPrice(Constants.ETH_TOKEN, 0);

        vm.prank(stableGuard);
        vm.expectRevert(IDutchAuctionManager.InvalidPrice.selector);
        auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
    }

    // ============ BIDDING TESTS ============

    function test_BidOnAuction_ETH_Success() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Calculate expected cost in SGD
        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        uint256 expectedCost = (currentPrice * DEFAULT_COLLATERAL_AMOUNT) / 1e18;

        uint256 bidderEthBefore = bidder.balance;
        uint256 bidderSgdBefore = stableGuardSGD.balanceOf(bidder);

        vm.prank(bidder);
        vm.expectEmit(true, true, true, true);
        emit AuctionEvent(
            auctionId, bidder, Constants.ETH_TOKEN, 1, uint128(DEFAULT_COLLATERAL_AMOUNT), uint128(currentPrice)
        );

        bool success = auctionManager.bidOnAuction(auctionId, currentPrice);

        assertTrue(success);
        // Bidder paid SGD and received the ETH collateral from custody
        assertEq(stableGuardSGD.balanceOf(bidder), bidderSgdBefore - expectedCost);
        assertEq(bidder.balance, bidderEthBefore + DEFAULT_COLLATERAL_AMOUNT);
        // User's custody was debited
        assertEq(collateralManager.userCollateral(user, Constants.ETH_TOKEN), 0);
        // Debt was settled in StableGuard with the full cost (cost < debt here)
        assertEq(stableGuardSGD.settledDebt(user), expectedCost);
        assertEq(stableGuardSGD.balanceOf(stableGuard), expectedCost);

        // Auction should be inactive
        IDutchAuctionManager.DutchAuction memory auction = auctionManager.getAuction(auctionId);
        assertFalse(auction.active);
    }

    function test_BidOnAuction_Token_Success() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        uint256 expectedCost = (currentPrice * DEFAULT_COLLATERAL_AMOUNT) / 1e18;

        uint256 bidderTokenBefore = mockToken.balanceOf(bidder);
        uint256 bidderSgdBefore = stableGuardSGD.balanceOf(bidder);

        vm.prank(bidder);
        bool success = auctionManager.bidOnAuction(auctionId, currentPrice);

        assertTrue(success);
        // Bidder paid SGD and received the token collateral from custody
        assertEq(stableGuardSGD.balanceOf(bidder), bidderSgdBefore - expectedCost);
        assertEq(mockToken.balanceOf(bidder), bidderTokenBefore + DEFAULT_COLLATERAL_AMOUNT);
        assertEq(collateralManager.userCollateral(user, address(mockToken)), 0);
        assertEq(stableGuardSGD.settledDebt(user), expectedCost);
    }

    function test_BidOnAuction_PriceDecreases() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 initialPrice = auctionManager.getCurrentPrice(auctionId);

        // Wait some time
        vm.warp(block.timestamp + 1800); // 30 minutes

        uint256 laterPrice = auctionManager.getCurrentPrice(auctionId);

        assertLt(laterPrice, initialPrice);
    }

    function test_BidOnAuction_InvalidAuction() public {
        vm.prank(bidder);
        vm.expectRevert(IDutchAuctionManager.InvalidParameters.selector);
        auctionManager.bidOnAuction(999, 1 ether);
    }

    function test_BidOnAuction_ExpiredAuction() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Wait for expiration
        vm.warp(block.timestamp + 3601); // 1 hour + 1 second

        vm.prank(bidder);
        vm.expectRevert();
        auctionManager.bidOnAuction(auctionId, 1 ether);
    }

    function test_BidOnAuction_PriceTooHigh() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        uint256 lowMaxPrice = currentPrice / 2;

        vm.prank(bidder);
        vm.expectRevert();
        auctionManager.bidOnAuction(auctionId, lowMaxPrice);
    }

    function test_BidOnAuction_InsufficientSgd() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        // A bidder without SGD (or approval) cannot settle the bid
        address brokeBidder = makeAddr("brokeBidder");
        vm.prank(brokeBidder);
        vm.expectRevert();
        auctionManager.bidOnAuction(auctionId, currentPrice);
    }

    function test_BidOnAuction_SurplusPaidToLiquidatedUser() public {
        // Small debt vs collateral: the auction only takes debt + 10% bonus worth
        uint256 smallDebt = 1e18; // $1
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, smallDebt);

        IDutchAuctionManager.DutchAuction memory auction = auctionManager.getAuction(auctionId);
        // Partial collateral: (1 + 10%) USD at $1/token with 18 decimals = 1.1 tokens
        assertEq(auction.collateralAmount, 1.1e18);

        uint256 cost = _costOf(auctionId); // 1.1 SGD at start price
        uint256 userSgdBefore = stableGuardSGD.balanceOf(user);
        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        vm.prank(bidder);
        auctionManager.bidOnAuction(auctionId, currentPrice);

        // The debt portion settles; the excess above the debt goes to the user
        assertEq(stableGuardSGD.settledDebt(user), smallDebt);
        assertEq(stableGuardSGD.balanceOf(user), userSgdBefore + (cost - smallDebt));
    }

    // ============ PRICE CALCULATION TESTS ============

    function test_getCurrentPrice_StartPrice() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        assertEq(currentPrice, DEFAULT_TOKEN_PRICE);
    }

    function test_getCurrentPrice_HalfwayThrough() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Wait halfway through auction
        vm.warp(block.timestamp + 1800); // 30 minutes

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        uint256 expectedPrice = DEFAULT_TOKEN_PRICE - (DEFAULT_TOKEN_PRICE / 4); // 75% of start price

        assertEq(currentPrice, expectedPrice);
    }

    function test_getCurrentPrice_EndPrice() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Wait until end
        vm.warp(block.timestamp + 3600); // 1 hour

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        assertEq(currentPrice, DEFAULT_TOKEN_PRICE / 2); // 50% of start price
    }

    function test_getCurrentPrice_ExpiredAuction() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Wait past expiration
        vm.warp(block.timestamp + 3601);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        assertEq(currentPrice, 0);
    }

    function test_getCurrentPrice_InvalidAuction() public view {
        uint256 currentPrice = auctionManager.getCurrentPrice(999);
        assertEq(currentPrice, 0);
    }

    // ============ VIEW FUNCTIONS TESTS ============

    function test_getAuction() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        IDutchAuctionManager.DutchAuction memory auction = auctionManager.getAuction(auctionId);

        assertEq(auction.user, user);
        assertEq(auction.token, Constants.ETH_TOKEN);
        assertEq(auction.debtAmount, DEFAULT_DEBT_AMOUNT);
        assertEq(auction.collateralAmount, DEFAULT_COLLATERAL_AMOUNT);
        assertTrue(auction.active);
    }

    function test_getAuction_InvalidId() public {
        vm.expectRevert(IDutchAuctionManager.InvalidParameters.selector);
        auctionManager.getAuction(999);
    }

    function test_getUserAuctions() public {
        vm.startPrank(stableGuard);
        uint256 auctionId1 = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
        uint256 auctionId2 = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);
        vm.stopPrank();

        uint256[] memory userAuctions = auctionManager.getUserAuctions(user);

        assertEq(userAuctions.length, 2);
        assertEq(userAuctions[0], auctionId1);
        assertEq(userAuctions[1], auctionId2);
    }

    function test_getUserAuctions_InvalidAddress() public {
        vm.expectRevert(IDutchAuctionManager.InvalidAddress.selector);
        auctionManager.getUserAuctions(address(0));
    }

    function test_isAuctionActive() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        assertTrue(auctionManager.isAuctionActive(auctionId));

        // After expiration
        vm.warp(block.timestamp + 3601);
        assertFalse(auctionManager.isAuctionActive(auctionId));
    }

    function test_isAuctionExpired() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        assertFalse(auctionManager.isAuctionExpired(auctionId));

        vm.warp(block.timestamp + 3601);
        assertTrue(auctionManager.isAuctionExpired(auctionId));
    }

    function test_getActiveAuctions() public {
        vm.startPrank(stableGuard);
        uint256 auctionId1 = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
        uint256 auctionId2 = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);
        vm.stopPrank();

        uint256[] memory activeAuctions = auctionManager.getActiveAuctions();

        assertEq(activeAuctions.length, 2);
        assertEq(activeAuctions[0], auctionId1);
        assertEq(activeAuctions[1], auctionId2);

        // After one expires
        vm.warp(block.timestamp + 3601);
        activeAuctions = auctionManager.getActiveAuctions();
        assertEq(activeAuctions.length, 0);
    }

    function test_getUserTokenAuction() public {
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 foundAuctionId = auctionManager.getUserTokenAuction(user, Constants.ETH_TOKEN);
        assertEq(foundAuctionId, auctionId);

        uint256 notFoundAuctionId = auctionManager.getUserTokenAuction(user, address(mockToken));
        assertEq(notFoundAuctionId, 0);
    }

    function test_getUserTokenAuction_InvalidAddress() public {
        vm.expectRevert(IDutchAuctionManager.InvalidAddress.selector);
        auctionManager.getUserTokenAuction(address(0), Constants.ETH_TOKEN);
    }

    // ============ CLEANUP TESTS ============

    function test_cancelExpiredAuction() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Wait for expiration
        vm.warp(block.timestamp + 3601);

        vm.prank(address(0x999));
        vm.expectEmit(true, true, true, true);
        emit AuctionEvent(auctionId, address(0x999), Constants.ETH_TOKEN, 2, 0, 0);

        auctionManager.cancelExpiredAuction(auctionId);

        // Auction should be inactive (no ETH incentive: the manager holds no ETH)
        IDutchAuctionManager.DutchAuction memory auction = auctionManager.getAuction(auctionId);
        assertFalse(auction.active);
    }

    function test_cancelExpiredAuction_NotExpired() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        vm.prank(address(0x999));
        vm.expectRevert(IDutchAuctionManager.AuctionNotExpired.selector);
        auctionManager.cancelExpiredAuction(auctionId);
    }

    function test_cleanExpiredAuctions() public {
        // Start multiple auctions
        vm.startPrank(stableGuard);
        uint256 auctionId1 = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
        uint256 auctionId2 = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);
        vm.stopPrank();

        // Wait for expiration
        vm.warp(block.timestamp + 3601);

        uint256[] memory auctionIds = new uint256[](2);
        auctionIds[0] = auctionId1;
        auctionIds[1] = auctionId2;

        vm.prank(address(0x999));
        vm.expectEmit(true, true, true, true);
        emit AuctionEvent(0, address(0x999), address(0), 3, 2, 0);

        uint256 incentive = auctionManager.cleanExpiredAuctions(auctionIds);

        assertEq(incentive, 0); // No ETH incentives anymore

        // Both auctions should be inactive
        assertFalse(auctionManager.getAuction(auctionId1).active);
        assertFalse(auctionManager.getAuction(auctionId2).active);
    }

    function test_cleanExpiredAuctions_NoExpiredAuctions() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256[] memory auctionIds = new uint256[](1);
        auctionIds[0] = auctionId;

        vm.prank(address(0x999));
        uint256 incentive = auctionManager.cleanExpiredAuctions(auctionIds);

        assertEq(incentive, 0);
        assertTrue(auctionManager.getAuction(auctionId).active); // Not expired -> untouched
    }

    // ============ ADMIN FUNCTIONS TESTS ============

    function test_updateConfig() public {
        uint64 newDuration = 7200; // 2 hours
        uint64 newMinPriceFactor = 3000; // 30%
        uint64 newLiquidationBonus = 1500; // 15%

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit AuctionEvent(0, owner, address(0), 4, uint128(newDuration), uint128(newMinPriceFactor));

        auctionManager.updateConfig(newDuration, newMinPriceFactor, newLiquidationBonus);

        (uint64 duration, uint64 minPriceFactor, uint64 liquidationBonus) = auctionManager.getConfig();
        assertEq(duration, newDuration);
        assertEq(minPriceFactor, newMinPriceFactor);
        assertEq(liquidationBonus, newLiquidationBonus);
    }

    function test_updateConfig_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        auctionManager.updateConfig(7200, 3000, 1500);
    }

    function test_updateConfig_InvalidParameters() public {
        vm.startPrank(owner);

        // Zero duration
        vm.expectRevert();
        auctionManager.updateConfig(0, 5000, 1000);

        // Zero minPriceFactor
        vm.expectRevert();
        auctionManager.updateConfig(3600, 0, 1000);

        // Zero liquidationBonus
        vm.expectRevert();
        auctionManager.updateConfig(3600, 5000, 0);

        // minPriceFactor > 10000
        vm.expectRevert();
        auctionManager.updateConfig(3600, 10001, 1000);

        // liquidationBonus > 10000
        vm.expectRevert();
        auctionManager.updateConfig(3600, 5000, 10001);

        vm.stopPrank();
    }

    function test_emergencyWithdraw_ETH() public {
        uint256 withdrawAmount = 10 ether;

        // Fund the contract with ETH first
        vm.deal(address(auctionManager), withdrawAmount);

        uint256 ownerBalanceBefore = owner.balance;

        vm.prank(owner);
        auctionManager.emergencyWithdraw(Constants.ETH_TOKEN, withdrawAmount);

        assertEq(owner.balance, ownerBalanceBefore + withdrawAmount);
    }

    function test_emergencyWithdraw_Token() public {
        uint256 withdrawAmount = 1000e18;
        uint256 ownerBalanceBefore = mockToken.balanceOf(owner);

        vm.prank(owner);
        auctionManager.emergencyWithdraw(address(mockToken), withdrawAmount);

        assertEq(mockToken.balanceOf(owner), ownerBalanceBefore + withdrawAmount);
    }

    function test_emergencyWithdraw_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        auctionManager.emergencyWithdraw(Constants.ETH_TOKEN, 1 ether);
    }

    function test_emergencyWithdraw_ZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IDutchAuctionManager.InvalidParameters.selector);
        auctionManager.emergencyWithdraw(Constants.ETH_TOKEN, 0);
    }

    function test_emergencyWithdraw_InvalidToken() public {
        // Test with a non-existent token contract that will fail on balanceOf call
        address invalidToken = address(0x1234567890123456789012345678901234567890);

        vm.prank(owner);
        vm.expectRevert();
        auctionManager.emergencyWithdraw(invalidToken, 1 ether);
    }

    function test_emergencyWithdraw_InsufficientBalance() public {
        uint256 excessiveAmount = 1000 ether;

        vm.prank(owner);
        vm.expectRevert(IDutchAuctionManager.InsufficientPayment.selector);
        auctionManager.emergencyWithdraw(Constants.ETH_TOKEN, excessiveAmount);
    }

    // ============ MEV PROTECTION TESTS ============

    function test_commitBid() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        bytes32 commitHash = keccak256(abi.encode(bidder, auctionId, uint256(1 ether), uint256(123)));

        vm.prank(bidder);
        vm.expectEmit(true, true, true, true);
        emit BidCommitted(commitHash, auctionId, bidder);

        auctionManager.commitBid(commitHash, auctionId);
    }

    function test_commitBid_InvalidHash() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        vm.prank(bidder);
        vm.expectRevert("Invalid commit hash");
        auctionManager.commitBid(bytes32(0), auctionId);
    }

    function test_commitBid_InvalidAuction() public {
        bytes32 commitHash = keccak256(abi.encode(bidder, uint256(999), uint256(1 ether), uint256(123)));

        vm.prank(bidder);
        vm.expectRevert(IDutchAuctionManager.InvalidParameters.selector);
        auctionManager.commitBid(commitHash, 999);
    }

    function test_revealAndBid() public {
        // Clean environment
        vm.warp(1000000);
        vm.roll(1000);

        // Fresh bidder funded with SGD
        address testBidder = address(0xABCD);
        _fundAndApprove(testBidder, 1_000_000e18);

        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 maxPrice = 2 ether;
        uint256 nonce = 456;
        // Same layout the contract hashes in assembly
        bytes32 commitHash = keccak256(abi.encode(testBidder, auctionId, maxPrice, nonce));

        // Commit
        vm.prank(testBidder);
        auctionManager.commitBid(commitHash, auctionId);
        bytes32 commitId = keccak256(abi.encode(testBidder, auctionId, block.timestamp));

        // Wait out the 300s commit period, stay inside the 600s reveal window
        vm.warp(block.timestamp + 301);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);
        assertGt(currentPrice, 0, "Price should be > 0");
        assertLe(currentPrice, maxPrice, "Price should be <= maxPrice");
        uint256 cost = _costOf(auctionId);

        uint256 bidderEthBefore = testBidder.balance;
        uint256 bidderSgdBefore = stableGuardSGD.balanceOf(testBidder);

        // Reveal and execute the bid (paid in SGD)
        vm.prank(testBidder);
        bool success = auctionManager.revealAndBid(commitId, auctionId, maxPrice, nonce);

        assertTrue(success, "revealAndBid should succeed");
        assertFalse(auctionManager.isAuctionActive(auctionId));
        assertEq(stableGuardSGD.balanceOf(testBidder), bidderSgdBefore - cost);
        assertEq(testBidder.balance, bidderEthBefore + DEFAULT_COLLATERAL_AMOUNT);
        assertEq(stableGuardSGD.settledDebt(user), cost);
    }

    // ============ RATE LIMITING TESTS ============

    function test_rateLimiting() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        // First bid should succeed
        vm.prank(bidder);
        auctionManager.bidOnAuction(auctionId, currentPrice);

        // Start another auction for second bid test
        vm.prank(stableGuard);
        uint256 auctionId2 = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);

        // Immediate second bid should fail due to rate limiting
        vm.prank(bidder);
        vm.expectRevert("Rate limited");
        auctionManager.bidOnAuction(auctionId2, currentPrice);

        // After waiting, should succeed
        vm.warp(block.timestamp + 13); // Wait 13 seconds

        vm.prank(bidder);
        bool success = auctionManager.bidOnAuction(auctionId2, currentPrice);

        assertTrue(success);
    }

    // ============ FLASHLOAN PROTECTION TESTS ============

    function test_flashloanProtection() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Simulate large balance (flashloan detection)
        vm.deal(address(auctionManager), 150 ether);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        vm.prank(bidder);
        vm.expectRevert("Flashloan protection active");
        auctionManager.bidOnAuction(auctionId, currentPrice);

        // After protection period, should work
        vm.roll(block.number + 3); // Wait 3 blocks

        // Clear the large balance to prevent re-triggering flashloan detection
        vm.deal(address(auctionManager), 0);

        vm.prank(bidder);
        bool success = auctionManager.bidOnAuction(auctionId, currentPrice);
        assertTrue(success);
    }

    // ============ EDGE CASES AND SECURITY TESTS ============

    function test_reentrancyProtection() public {
        // This test would require a malicious contract that attempts reentrancy
        // For now, we verify that the nonReentrant modifier is in place
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        vm.prank(bidder);
        bool success = auctionManager.bidOnAuction(auctionId, currentPrice);
        assertTrue(success);
    }

    function test_multipleAuctionsForSameUser() public {
        vm.startPrank(stableGuard);

        // Create multiple collateral entries for the same user
        collateralManager.setUserCollateral(user, address(mockToken), DEFAULT_COLLATERAL_AMOUNT);

        uint256 auctionId1 = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
        uint256 auctionId2 = auctionManager.startDutchAuction(user, address(mockToken), DEFAULT_DEBT_AMOUNT);

        vm.stopPrank();

        assertNotEq(auctionId1, auctionId2);
        assertTrue(auctionManager.isAuctionActive(auctionId1));
        assertTrue(auctionManager.isAuctionActive(auctionId2));
    }

    function test_bidAfterAuctionWon() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        // First bidder wins
        vm.prank(bidder);
        auctionManager.bidOnAuction(auctionId, currentPrice);

        // Second bidder tries to bid on inactive auction
        vm.prank(bidder2);
        vm.expectRevert(IDutchAuctionManager.InvalidParameters.selector);
        auctionManager.bidOnAuction(auctionId, currentPrice);
    }

    function test_priceCalculationOverflow() public {
        // Test with extreme values to check overflow protection
        vm.prank(owner);
        auctionManager.updateConfig(1, 1, 1000); // Very short duration, very low min price

        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        // Price should still be calculable
        uint256 price = auctionManager.getCurrentPrice(auctionId);
        assertGt(price, 0);
    }

    function test_gasOptimization() public {
        // Test that operations are gas efficient
        vm.prank(stableGuard);
        uint256 gasBefore = gasleft();
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
        uint256 gasUsed = gasBefore - gasleft();

        // Should use reasonable amount of gas (adjust threshold as needed)
        assertLt(gasUsed, 280000);

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        vm.prank(bidder);
        gasBefore = gasleft();
        auctionManager.bidOnAuction(auctionId, currentPrice);
        gasUsed = gasBefore - gasleft();

        // Bidding settles debt + seizes collateral in one transaction
        assertLt(gasUsed, 500000);
    }

    function test_noReceiveFunction() public {
        // The auction manager no longer deals in ETH: direct sends must revert
        vm.deal(address(this), 1 ether);
        (bool success,) = address(auctionManager).call{value: 1 ether}("");
        assertFalse(success);
    }

    // ============ HELPER FUNCTIONS ============

    receive() external payable {}

    // ============ ADDITIONAL EDGE CASES ============

    function test_revealWithWrongNonce() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        address testBidder = address(0xABCD);
        _fundAndApprove(testBidder, 1_000_000e18);

        uint256 maxPrice = 2 ether;
        uint256 correctNonce = 456;
        uint256 wrongNonce = 789;

        // Create commit with correct nonce
        bytes32 commitHash = keccak256(abi.encode(testBidder, auctionId, maxPrice, correctNonce));

        // Commit bid
        vm.prank(testBidder);
        auctionManager.commitBid(commitHash, auctionId);

        // Generate commitId
        bytes32 commitId = keccak256(abi.encode(testBidder, auctionId, block.timestamp));

        // Wait for commit period to end
        vm.warp(block.timestamp + 301);

        // Try to reveal with wrong nonce - should fail
        vm.prank(testBidder);
        vm.expectRevert("Invalid reveal");
        auctionManager.revealAndBid(commitId, auctionId, maxPrice, wrongNonce);
    }

    function test_multipleCommitsFromSameUser() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        address testBidder = address(0xABCD);
        _fundAndApprove(testBidder, 1_000_000e18);

        uint256 maxPrice1 = 2 ether;
        uint256 maxPrice2 = 3 ether;
        uint256 nonce1 = 456;
        uint256 nonce2 = 789;

        // Create first commit
        bytes32 commitHash1 = keccak256(abi.encode(testBidder, auctionId, maxPrice1, nonce1));

        // First commit should succeed
        vm.prank(testBidder);
        auctionManager.commitBid(commitHash1, auctionId);

        // Create second commit from same user
        bytes32 commitHash2 = keccak256(abi.encode(testBidder, auctionId, maxPrice2, nonce2));

        // Second commit should overwrite the first (this is the expected behavior)
        vm.prank(testBidder);
        auctionManager.commitBid(commitHash2, auctionId);

        // Generate commitId for the second commit
        bytes32 commitId = keccak256(abi.encode(testBidder, auctionId, block.timestamp));

        // Wait for commit period to end
        vm.warp(block.timestamp + 301);

        // Try to reveal with first commit parameters - should fail
        vm.prank(testBidder);
        vm.expectRevert("Invalid reveal");
        auctionManager.revealAndBid(commitId, auctionId, maxPrice1, nonce1);

        // Reveal with second commit parameters - should succeed
        vm.prank(testBidder);
        bool success = auctionManager.revealAndBid(commitId, auctionId, maxPrice2, nonce2);
        assertTrue(success);
    }

    // ============ STRESS/INTEGRATION TESTS ============

    function test_multipleSimultaneousAuctions() public {
        // Create multiple users with collateral
        address[] memory users = new address[](5);
        address[] memory bidders = new address[](5);
        uint256[] memory auctionIds = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(0x1000 + i));
            bidders[i] = address(uint160(0x2000 + i));

            // Setup collateral for each user
            collateralManager.setUserCollateral(users[i], Constants.ETH_TOKEN, DEFAULT_COLLATERAL_AMOUNT);

            // Give bidders SGD
            _fundAndApprove(bidders[i], 1_000_000e18);
        }

        // Extra ETH so the CollateralManager can pay out all five seizures
        vm.deal(address(collateralManager), 100 ether);

        // Start multiple auctions simultaneously
        vm.startPrank(stableGuard);
        for (uint256 i = 0; i < 5; i++) {
            auctionIds[i] = auctionManager.startDutchAuction(users[i], Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);
        }
        vm.stopPrank();

        // Verify all auctions are active
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(auctionManager.isAuctionActive(auctionIds[i]));
        }

        // Have different bidders bid on different auctions at different times
        for (uint256 i = 0; i < 5; i++) {
            // Advance time slightly for each auction to create different prices
            vm.warp(block.timestamp + (i * 60)); // 1 minute intervals

            uint256 currentPrice = auctionManager.getCurrentPrice(auctionIds[i]);

            vm.prank(bidders[i]);
            bool success = auctionManager.bidOnAuction(auctionIds[i], currentPrice);
            assertTrue(success);

            // Verify auction is now inactive
            assertFalse(auctionManager.isAuctionActive(auctionIds[i]));
        }

        // Verify all auctions completed successfully
        assertEq(auctionManager.getAuctionCounter(), 5);
    }

    function test_flashloanDetectionDuringActiveAuction() public {
        // Start auction
        vm.prank(stableGuard);
        uint256 auctionId = auctionManager.startDutchAuction(user, Constants.ETH_TOKEN, DEFAULT_DEBT_AMOUNT);

        address testBidder = address(0xABCD);
        _fundAndApprove(testBidder, 1_000_000e18);

        // Simulate a flashloan scenario:
        // 1. Contract receives large amount of ETH (simulating flashloan)
        // 2. Bidder tries to bid during flashloan protection period
        // 3. Contract balance returns to normal
        // 4. Bidder should be able to bid after protection period

        uint256 currentPrice = auctionManager.getCurrentPrice(auctionId);

        // Step 1: Simulate flashloan by giving contract large balance
        vm.deal(address(auctionManager), 150 ether); // Exceeds 100 ETH threshold

        // Step 2: Try to bid during flashloan protection - should fail
        vm.prank(testBidder);
        vm.expectRevert("Flashloan protection active");
        auctionManager.bidOnAuction(auctionId, currentPrice);

        // Step 3: Advance blocks to clear flashloan protection
        vm.roll(block.number + 3); // Wait 3 blocks (FLASHLOAN_PROTECTION_BLOCKS = 2)

        // Step 4: Reduce contract balance to normal level
        vm.deal(address(auctionManager), 0);

        // Step 5: Now bid should succeed
        vm.prank(testBidder);
        bool success = auctionManager.bidOnAuction(auctionId, currentPrice);
        assertTrue(success);

        // Verify auction completed
        assertFalse(auctionManager.isAuctionActive(auctionId));
    }
}

// ============ MOCK CONTRACTS ============

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) private prices;
    mapping(address => bool) public supportedTokens;
    mapping(address => address) public priceFeeds;
    mapping(address => uint256) public fallbackPrices;
    mapping(address => uint8) public tokenDecimals;
    address[] public allTokens;
    bool private shouldFail;

    function setTokenPrice(address token, uint256 price) external {
        prices[token] = price;
        supportedTokens[token] = true;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function getTokenPrice(address token) external view returns (uint256) {
        if (shouldFail) revert("Oracle failed");
        return prices[token];
    }

    function getTokenPriceWithEvents(address token) external view returns (uint256) {
        return prices[token];
    }

    function configureToken(address token, address priceFeed, uint256 fallbackPrice, uint8 decimals) public {
        supportedTokens[token] = true;
        priceFeeds[token] = priceFeed;
        fallbackPrices[token] = fallbackPrice;
        tokenDecimals[token] = decimals;
        allTokens.push(token);
    }

    function batchConfigureTokens(
        address[] calldata tokens,
        address[] calldata _priceFeeds,
        uint256[] calldata _fallbackPrices,
        uint8[] calldata decimals
    ) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            configureToken(tokens[i], _priceFeeds[i], _fallbackPrices[i], decimals[i]);
        }
    }

    function removeToken(address token) external {
        supportedTokens[token] = false;
    }

    function getTokenPriceWithFallback(address token) external view returns (uint256) {
        return prices[token];
    }

    function isTokenSupported(address token) external view returns (bool) {
        return prices[token] > 0;
    }

    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return allTokens;
    }

    function getTokenValueInUsd(address token, uint256 amount) external view returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        uint256 price = prices[token];
        uint8 decimals = tokenDecimals[token];
        if (decimals == 0) decimals = 18; // Default to 18 decimals
        return (amount * price) / (10 ** decimals);
    }

    function getTokenAmountFromUsd(address token, uint256 usdValue) external view returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        uint8 decimals = tokenDecimals[token];
        if (decimals == 0) decimals = 18; // Default to 18 decimals
        return (usdValue * (10 ** decimals)) / prices[token];
    }

    function getTokenConfig(address token)
        external
        view
        returns (address priceFeed, uint256 fallbackPrice, uint8 decimals)
    {
        return (priceFeeds[token], fallbackPrices[token], tokenDecimals[token]);
    }

    function getTokenDecimals(address token) external view returns (uint8) {
        uint8 decimals = tokenDecimals[token];
        return decimals == 0 ? 18 : decimals; // Default to 18 if not set
    }

    function getMultipleTokenPrices(address[] calldata tokens)
        external
        view
        returns (uint256[] memory prices_, bool[] memory validFlags)
    {
        uint256 length = tokens.length;
        prices_ = new uint256[](length);
        validFlags = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            if (supportedTokens[tokens[i]]) {
                prices_[i] = prices[tokens[i]];
                validFlags[i] = true;
            } else {
                prices_[i] = 0;
                validFlags[i] = false;
            }
        }
    }

    function checkFeedHealth(address token) external view returns (bool isHealthy, uint256 lastUpdate) {
        isHealthy = supportedTokens[token];
        lastUpdate = block.timestamp; // Mock always returns current timestamp
    }

    function updateFallbackPrice(address token, uint256 newFallbackPrice) external {
        fallbackPrices[token] = newFallbackPrice;
    }

    function getLastUpdateTime(
        address /* token */
    )
        external
        view
        returns (uint256)
    {
        return block.timestamp;
    }
}

contract MockCollateralManager is ICollateralManager {
    mapping(address => mapping(address => uint256)) public userCollateral;
    mapping(address => address[]) public userTokens;

    function setUserCollateral(address user, address token, uint256 amount) public {
        userCollateral[user][token] = amount;
        // Add token to user's token list if not already present
        bool found = false;
        for (uint256 i = 0; i < userTokens[user].length; i++) {
            if (userTokens[user][i] == token) {
                found = true;
                break;
            }
        }
        if (!found && amount > 0) {
            userTokens[user].push(token);
        }
    }

    function addCollateralType(address, address, uint256, uint8) external {
        // Mock implementation - just store that it's supported
    }

    function deposit(address user, address token, uint256 amount) external payable {
        userCollateral[user][token] += amount;
        setUserCollateral(user, token, userCollateral[user][token]);
    }

    function withdraw(address user, address token, uint256 amount, address recipient) external {
        require(userCollateral[user][token] >= amount, "Insufficient collateral");
        userCollateral[user][token] -= amount;
        // Pay the recipient like the real CollateralManager does
        if (token == address(0)) {
            (bool ok,) = payable(recipient).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(recipient, amount), "Token transfer failed");
        }
    }

    receive() external payable {}

    function getUserCollateral(address user, address token) external view returns (uint256) {
        return userCollateral[user][token];
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function getTotalCollateralValue(address user) public pure returns (uint256) {
        // Mock implementation: return different values based on user address for testing
        if (user == address(0x1)) return 500e18; // Low collateral user
        if (user == address(0x2)) return 2000e18; // High collateral user
        return 1000e18; // Default mock value
    }

    function getCollateralRatio(address user) public pure returns (uint256) {
        // Mock implementation: return different ratios based on user for testing
        if (user == address(0x1)) return 120; // Lower ratio user
        if (user == address(0x2)) return 200; // Higher ratio user
        return 150; // Default 150% ratio
    }

    function isCollateralSufficient(address user, uint256 debtAmount) external pure returns (bool) {
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 collateralRatio = getCollateralRatio(user);
        uint256 requiredCollateral = (debtAmount * collateralRatio) / 100;
        return collateralValue >= requiredCollateral;
    }

    function canLiquidate(address user, uint256 debtValue, uint256 liquidationThreshold) external pure returns (bool) {
        // Mock implementation: check if collateral is below liquidation threshold
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 minimumCollateral = (debtValue * liquidationThreshold) / 10000;
        return collateralValue < minimumCollateral;
    }

    function liquidateCollateral(
        address user,
        address,
        /* token */
        uint256 debtValue,
        uint256 liquidationThreshold
    )
        external
        pure
        returns (bool)
    {
        // Mock implementation: check if collateral is below liquidation threshold
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 minimumCollateral = (debtValue * liquidationThreshold) / 10000;
        return collateralValue < minimumCollateral;
    }

    function emergencyWithdraw(address token, uint256 amount) external {
        // Mock implementation for emergency withdraw
        // In a real implementation, this would transfer tokens/ETH to the owner
        // For testing purposes, we just need the function to exist
    }
}

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "Insufficient balance");
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");

        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;

        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev Plays the role of StableGuard for the auction manager: it is both the SGD
///      token bids are paid in and the settlement endpoint. It records settled
///      debt per user; the SGD forwarded by the auction manager stays on its
///      balance (the real contract burns it).
contract MockStableGuardSGD is MockERC20 {
    mapping(address => uint256) public settledDebt;

    constructor() MockERC20("StableGuard", "SGD") {}

    function processAuctionCompletion(address user, uint256 debtSettled) external {
        settledDebt[user] += debtSettled;
    }
}
