// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StableGuard} from "../src/StableGuard.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ICollateralManager} from "../src/interfaces/ICollateralManager.sol";
import {ILiquidationManager} from "../src/interfaces/ILiquidationManager.sol";
import {IDutchAuctionManager} from "../src/interfaces/IDutchAuctionManager.sol";
import {Constants} from "../src/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRepegManager} from "../src/interfaces/IRepegManager.sol";
import {Timelock} from "../src/Timelock.sol";
import {RateLimiter} from "../src/RateLimiter.sol";
import {console} from "forge-std/console.sol";

// =====================
// Mock Contracts
// =====================

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;
    mapping(address => bool) public supported;
    mapping(address => uint8) public tokenDecimals;

    function setTokenPrice(address token, uint256 price) external {
        prices[token] = price;
        supported[token] = true;
    }

    function setTokenDecimals(address token, uint8 dec) external {
        tokenDecimals[token] = dec;
    }

    function addSupportedToken(address token) external {
        supported[token] = true;
    }

    // Core/view used by StableGuard
    function isSupportedToken(address token) external view returns (bool) {
        return supported[token];
    }

    function getTokenValueInUsd(address token, uint256 amount) external view returns (uint256) {
        require(supported[token], "Token not supported");
        uint256 price = prices[token];
        uint8 dec = tokenDecimals[token] == 0 ? 18 : tokenDecimals[token];
        return (amount * price) / (10 ** dec);
    }

    function getTokenAmountFromUsd(address token, uint256 usdValue) external view returns (uint256) {
        require(supported[token], "Token not supported");
        uint8 dec = tokenDecimals[token] == 0 ? 18 : tokenDecimals[token];
        return (usdValue * (10 ** dec)) / prices[token];
    }

    // Unused in these tests but required by interface
    function getTokenPrice(address token) external view returns (uint256) {
        return prices[token];
    }

    function getTokenPriceWithEvents(address token) external view returns (uint256) {
        return prices[token];
    }

    function configureToken(address, address, uint256, uint8) external {}
    function removeToken(address) external {}
    function batchConfigureTokens(address[] calldata, address[] calldata, uint256[] calldata, uint8[] calldata)
        external {}

    function getSupportedTokens() external pure returns (address[] memory) {
        address[] memory a;
        return a;
    }

    function getTokenConfig(address) external pure returns (address, uint256, uint8) {
        return (address(0), 0, 0);
    }

    function getTokenDecimals(address token) external view returns (uint8) {
        return tokenDecimals[token];
    }

    function getMultipleTokenPrices(address[] calldata tokens)
        external
        view
        returns (uint256[] memory _prices, bool[] memory flags)
    {
        _prices = new uint256[](tokens.length);
        flags = new bool[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            _prices[i] = prices[tokens[i]];
            flags[i] = supported[tokens[i]];
        }
    }

    function checkFeedHealth(address token) external view returns (bool, uint256) {
        return (supported[token], block.timestamp);
    }

    function updateFallbackPrice(address, uint256) external {}
}

contract MockCollateralManager is ICollateralManager {
    mapping(address => mapping(address => uint256)) public userCollateral;
    mapping(address => uint256) public totalCollateralValue;
    mapping(address => address[]) public userTokens;

    function setUserCollateral(address user, address token, uint256 amount) public {
        userCollateral[user][token] = amount;
        // track token list
        bool found = false;
        for (uint256 i = 0; i < userTokens[user].length; i++) {
            if (userTokens[user][i] == token) {
                found = true;
                break;
            }
        }
        if (!found && amount > 0) userTokens[user].push(token);
    }

    function setTotalCollateralValue(address user, uint256 value) external {
        totalCollateralValue[user] = value;
    }

    function addCollateralType(address, address, uint256, uint8) external {}

    function deposit(address user, address token, uint256 amount) external payable {
        userCollateral[user][token] += amount;
        setUserCollateral(user, token, userCollateral[user][token]);
    }

    function withdraw(address user, address token, uint256 amount, address recipient) external {
        require(userCollateral[user][token] >= amount, "Insufficient collateral");
        userCollateral[user][token] -= amount;
        // Simulate real CollateralManager behavior: pay the recipient directly
        if (token == Constants.ETH_TOKEN) {
            (bool success,) = payable(recipient).call{value: amount}("");
            require(success, "ETH forward failed");
        } else {
            bool ok = IERC20(token).transfer(recipient, amount);
            require(ok, "Transfer failed");
        }
    }

    function getUserCollateral(address user, address token) external view returns (uint256) {
        return userCollateral[user][token];
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function getTotalCollateralValue(address user) external view returns (uint256) {
        return totalCollateralValue[user];
    }

    function canLiquidate(address user, uint256 debtValue, uint256 liquidationThreshold) external view returns (bool) {
        uint256 cv = totalCollateralValue[user];
        return cv * 10000 < debtValue * liquidationThreshold;
    }

    function getCollateralRatio(address) external pure returns (uint256) {
        return 150;
    }

    function isCollateralSufficient(address user, uint256 debtAmount) external view returns (bool) {
        return totalCollateralValue[user] >= (debtAmount * 120) / 100;
    }

    function liquidateCollateral(address user, address, uint256 debtValue, uint256 liquidationThreshold)
        external
        view
        returns (bool)
    {
        uint256 cv = totalCollateralValue[user];
        return cv * 10000 < debtValue * liquidationThreshold;
    }

    function emergencyWithdraw(address, uint256) external {}
}

contract MockLiquidationManager is ILiquidationManager {
    address public stableGuard;
    address public optimalToken;
    bool public shouldSucceed = true;

    function setOptimalToken(address token) external {
        optimalToken = token;
    }

    function setShouldSucceed(bool s) external {
        shouldSucceed = s;
    }

    // Core functions used by StableGuard
    function findOptimalTokenForLiquidation(address) external view returns (address) {
        return optimalToken;
    }

    function findOptimalToken(address) external view returns (address) {
        return optimalToken;
    }

    function isLiquidatable(address) external pure returns (bool) {
        return true;
    }

    function getCollateralRatio(address) external pure returns (uint256) {
        return 15000;
    }

    function setStableGuard(address _guard) external {
        stableGuard = _guard;
    }

    function calculateLiquidationAmounts(address, address, uint256 debtAmount)
        external
        pure
        returns (uint256 collateralAmount, uint256 liquidationBonus)
    {
        return (debtAmount, 0);
    }

    function isPositionSafe(address, uint256, bool) external pure returns (bool) {
        return true;
    }

    function calculateCollateralFromDebt(uint256 debtValue, uint256) external pure returns (uint256) {
        return debtValue;
    }

    function getLiquidationConstants() external pure returns (uint256, uint256, uint256) {
        return (15000, 12000, 1000);
    }

    function getConfig() external pure returns (address, uint64, uint32, uint32) {
        return (address(0), 15000, 12000, 1000);
    }
}

contract MockDutchAuctionManager is IDutchAuctionManager {
    uint256 public counter;

    struct Last {
        address user;
        address token;
        uint256 debt;
    }

    Last public last;

    function startDutchAuction(address user, address token, uint256 debtAmount) external returns (uint256) {
        counter += 1;
        last = Last(user, token, debtAmount);
        return counter;
    }

    // Unused interface functions
    function setStableGuard(address) external {}

    function getAuctionCounter() external view returns (uint256) {
        return counter;
    }

    function getAuction(uint256) external view returns (DutchAuction memory auction) {
        // Mirror the real contract: return a populated struct for the last auction
        auction.user = last.user;
        auction.token = last.token;
        auction.debtAmount = uint96(last.debt);
        auction.active = counter > 0;
        auction.tokenDecimals = 18;
    }

    function getConfig() external pure returns (uint64, uint64, uint64) {
        return (3600, 5000, 1000);
    }

    function getCurrentPrice(uint256) external pure returns (uint256) {
        return 0;
    }

    function bidOnAuction(uint256, uint256) external returns (bool) {
        return false;
    }

    // Additional required interface functions
    function getActiveAuctions() external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    mapping(address => mapping(address => uint256)) public activeUserTokenAuction;

    function setUserTokenAuction(address user, address token, uint256 auctionId) external {
        activeUserTokenAuction[user][token] = auctionId;
    }

    function getUserTokenAuction(address user, address token) external view returns (uint256) {
        return activeUserTokenAuction[user][token];
    }

    function cleanExpiredAuctions(uint256[] calldata) external pure returns (uint256) {
        return 0;
    }

    function isAuctionExpired(uint256) external pure returns (bool) {
        return false;
    }

    function emergencyWithdraw(address, uint256) external {}
}

// New mock for RepegManager
contract MockRepegManager is IRepegManager {
    RepegConfig public config = RepegConfig({
        targetPrice: 1e18,
        deviationThreshold: 500,
        repegCooldown: 3600,
        arbitrageWindow: 600,
        incentiveRate: 100,
        maxRepegPerDay: 5,
        enabled: true
    });

    RepegState public state = RepegState({
        currentPrice: 1e18,
        lastRepegTime: 0,
        dailyRepegCount: 0,
        lastResetDay: 0,
        consecutiveRepegs: 0,
        repegDirection: 0,
        inProgress: false
    });

    uint256 public totalLiquidity;
    uint256 public availableLiquidity;
    bool public paused;

    // Core functions
    function checkAndTriggerRepeg(
        address /* beneficiary */
    )
        external
        returns (bool triggered, uint128 newPrice)
    {
        state.inProgress = false;
        return (true, state.currentPrice);
    }

    function executeRepeg(uint128 targetPrice, uint8 direction) external returns (bool success) {
        state.currentPrice = targetPrice;
        state.repegDirection = direction;
        state.lastRepegTime = uint64(block.timestamp);
        return true;
    }

    function calculateRepegParameters()
        external
        pure
        returns (uint128 targetPrice, uint8 direction, uint128 incentive)
    {
        return (1e18, 1, 100);
    }

    // Arbitrage functions
    function executeArbitrage(
        uint256 amount,
        uint128 /* maxSlippage */
    )
        external
        payable
        returns (uint128 profit)
    {
        return uint128(amount / 100);
    }

    function getArbitrageOpportunities() external view returns (ArbitrageOpportunity[] memory opportunities) {
        opportunities = new ArbitrageOpportunity[](1);
        opportunities[0] = ArbitrageOpportunity({
            tokenA: address(0xAAA),
            tokenB: address(0xBBB),
            amountIn: 1000,
            expectedProfit: 10,
            confidence: 90,
            expiryTime: uint64(block.timestamp + 300)
        });
    }

    // Liquidity functions
    function provideLiquidity(uint256 amount) external payable returns (bool success) {
        require(!paused, "paused");
        totalLiquidity += amount;
        availableLiquidity += amount;
        return true;
    }

    function withdrawLiquidity(uint256 amount) external returns (bool success) {
        require(availableLiquidity >= amount && totalLiquidity >= amount, "insufficient");
        totalLiquidity -= amount;
        availableLiquidity -= amount;
        return true;
    }

    function withdrawEthLiquidity(uint256 amount) external returns (bool success) {
        require(availableLiquidity >= amount && totalLiquidity >= amount, "insufficient");
        totalLiquidity -= amount;
        availableLiquidity -= amount;
        return true;
    }

    // Configuration functions
    function updateRepegConfig(RepegConfig calldata newConfig) external {
        config = newConfig;
    }

    function setEmergencyPause(bool _paused) external {
        paused = _paused;
    }

    function updateDeviationThreshold(uint64 newThreshold) external {
        config.deviationThreshold = newThreshold;
    }

    function updateIncentiveParameters(
        uint16 rate,
        uint128 /* maxIncentive */
    )
        external
    {
        config.incentiveRate = rate;
    }

    // View / nonpayable functions
    function getRepegConfig() external view returns (RepegConfig memory) {
        return config;
    }

    function getRepegState() external view returns (RepegState memory) {
        return state;
    }

    function isRepegNeeded() external pure returns (bool needed, uint128 currentDeviation) {
        return (true, 100);
    }

    function getCurrentDeviation() external pure returns (uint128 deviation, bool isAbove) {
        return (50, true);
    }

    function calculateIncentive(
        address /* caller */
    )
        external
        pure
        returns (uint128 incentive)
    {
        return 10;
    }

    function getLiquidityPoolStatus() external view returns (uint256, uint256) {
        return (totalLiquidity, availableLiquidity);
    }

    function getRepegHistory(
        uint256 /* count */
    )
        external
        view
        returns (uint128[] memory prices, uint64[] memory timestamps)
    {
        prices = new uint128[](1);
        prices[0] = 1e18;
        timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp);
    }

    function canTriggerRepeg() external pure returns (bool canTrigger, string memory reason) {
        return (true, "");
    }

    function getOptimalRepegTiming() external view returns (uint64 nextOptimalTime, uint32 confidence) {
        return (uint64(block.timestamp + 60), 100);
    }

    function emergencyWithdraw() external {}
}

// =====================
// StableGuard Tests
// =====================

contract StableGuardTest is Test {
    StableGuard public stableGuard;
    MockPriceOracle public priceOracle;
    MockCollateralManager public collateralManager;
    MockLiquidationManager public liquidationManager;
    MockDutchAuctionManager public auctionManager;
    MockERC20 public mockToken;
    MockRepegManager public repegManager;

    address public owner = address(this);
    address public user = address(0x111);
    address public liquidator = address(0x222);
    address public repeg = address(0x333); // dummy non-zero address
    address public timelock; // impersonated for governance calls in tests

    function setUp() public {
        // Ensure timestamp is far from zero to avoid cooldown triggering on first op
        vm.warp(1_000_000);

        // Deploy mocks
        priceOracle = new MockPriceOracle();
        collateralManager = new MockCollateralManager();
        liquidationManager = new MockLiquidationManager();
        auctionManager = new MockDutchAuctionManager();
        repegManager = new MockRepegManager();
        mockToken = new MockERC20("Mock Token", "MTK");

        // Configure oracle support
        priceOracle.addSupportedToken(Constants.ETH_TOKEN);
        priceOracle.setTokenDecimals(Constants.ETH_TOKEN, 18);
        priceOracle.setTokenPrice(Constants.ETH_TOKEN, 2000e18); // $2000 per ETH

        priceOracle.addSupportedToken(address(mockToken));
        priceOracle.setTokenDecimals(address(mockToken), 18);
        priceOracle.setTokenPrice(address(mockToken), 1e18); // $1 per token

        // A plain address stands in for the Timelock: governance calls are made by
        // pranking it. The Timelock's own queue/execute flow is covered in Timelock.t.sol.
        timelock = makeAddr("timelock");

        // Deploy StableGuard
        stableGuard = new StableGuard(
            address(priceOracle),
            address(collateralManager),
            address(liquidationManager),
            address(auctionManager),
            address(repegManager),
            timelock
        );

        // Reset rate-limiting state to a clean slate for tests
        stableGuard.resetGlobalRateLimit();
        stableGuard.resetUserRateLimit(user);
        // Pause rate limiting globally for baseline tests; specific tests will unpause explicitly
        stableGuard.setRateLimitingPause(true);
    }

    function test_Constructor_Initialized() public view {
        // Basic checks
        assertEq(stableGuard.name(), "StableGuard");
        assertEq(stableGuard.symbol(), "SGD");

        // Config defaults
        StableGuard.PackedConfig memory cfg = stableGuard.getSystemConfig();
        assertEq(cfg.minCollateralRatio, 15000);
        assertEq(cfg.liquidationThreshold, 12000);
        assertEq(cfg.emergencyThreshold, 11000);
        assertEq(cfg.maxLiquidationBonus, 1000);
        assertEq(cfg.emergencyDelay, 3600);
    }

    function test_DepositAndMint_ETH_Success() public {
        uint256 depositAmount = 1 ether; // $2000
        uint256 mintAmount = 1000e18; // $1000 debt => 200% ratio
        collateralManager.setTotalCollateralValue(user, 0);
        vm.deal(user, depositAmount);

        vm.prank(user);
        stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, mintAmount);

        assertEq(stableGuard.balanceOf(user), mintAmount);
        StableGuard.UserPosition memory pos = stableGuard.getUserPosition(user);
        assertEq(pos.debt, mintAmount);
        assertEq(collateralManager.getUserCollateral(user, Constants.ETH_TOKEN), depositAmount);
    }

    function test_GetLiquidationThreshold_ReadsPackedConfig() public {
        uint256 depositAmount = 1 ether;
        uint256 mintAmount = 1000e18;
        collateralManager.setTotalCollateralValue(user, 0);
        vm.deal(user, depositAmount);

        vm.prank(user);
        stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, mintAmount);

        // Default liquidationThreshold = 12000 bps -> debt * 1.2 (the old assembly
        // version read the priceOracle address slot instead of the config)
        assertEq(stableGuard.getLiquidationThreshold(user), (mintAmount * 12000) / 10000);
        assertEq(stableGuard.getLiquidationThreshold(makeAddr("nobody")), 0);
    }

    function test_DepositAndMint_Token_Success() public {
        uint256 depositAmount = 200e18; // $200
        uint256 mintAmount = 100e18; // $100 debt => 200% ratio
        collateralManager.setTotalCollateralValue(user, 0);

        // fund user with mock token
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        assertEq(stableGuard.balanceOf(user), mintAmount);
        assertEq(collateralManager.getUserCollateral(user, address(mockToken)), depositAmount);
    }

    function test_DepositAndMint_InvalidAmounts_Reverts() public {
        // Setup user with tokens
        uint256 depositAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);

        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        // mintAmount = 0 triggers assembly revert selector 0x7c946ed7 ("Invalid amounts")
        vm.expectRevert(bytes4(0x7c946ed7));
        stableGuard.depositAndMint(address(mockToken), depositAmount, 0);
        vm.stopPrank();
    }

    function test_StableGuard_ReceiveETH_Success() public {
        // StableGuard must accept ETH via receive()
        vm.deal(address(this), 1 ether);
        (bool success,) = address(stableGuard).call{value: 1 ether}("");
        assertTrue(success);
    }

    // Missing tests added below

    function test_Liquidate_CannotLiquidateSelf_Reverts() public {
        // Setup a position for user
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // User tries to liquidate self
        vm.expectRevert("Cannot liquidate self");
        vm.prank(user);
        stableGuard.liquidate(user, 10e18);

        // Specific token overload
        vm.expectRevert("Cannot liquidate self");
        vm.prank(user);
        stableGuard.liquidate(user, address(mockToken), 10e18);
    }

    function test_Liquidate_NoPosition_Reverts() public {
        // Ensure user has no position (no debt)
        StableGuard.UserPosition memory pos = stableGuard.getUserPosition(user);
        assertEq(pos.debt, 0);

        vm.expectRevert(bytes4(0x7c946ed7)); // "No position" via validPosition modifier
        vm.prank(liquidator);
        stableGuard.liquidate(user, 10e18);

        vm.expectRevert(bytes4(0x7c946ed7)); // "No position" for specific token overload
        vm.prank(liquidator);
        stableGuard.liquidate(user, address(mockToken), 10e18);
    }

    function test_EmergencyLiquidate_RevertWithoutSgdAllowance() public {
        // Setup position
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // The owner must supply the SGD being retired; without allowance it reverts
        vm.expectRevert();
        vm.prank(owner);
        stableGuard.emergencyLiquidate(user, address(mockToken), 50e18);
    }

    function test_UpdateModules_InvalidAddresses_Revert() public {
        // Zero address for one of the modules should revert
        vm.expectRevert("Invalid addresses");
        vm.prank(timelock);
        stableGuard.updateModules(
            address(priceOracle),
            address(collateralManager),
            address(0), // invalid
            address(auctionManager),
            repeg
        );
    }

    function test_DepositAndMint_ETH_InvalidAmounts_Reverts() public {
        // ETH deposit with zero mint amount should revert via assembly selector
        uint256 depositAmount = 1 ether;
        vm.deal(user, depositAmount);
        collateralManager.setTotalCollateralValue(user, 0);

        vm.startPrank(user);
        // depositAmount ok, mintAmount zero -> invalid amounts
        vm.expectRevert(bytes4(0x7c946ed7));
        stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, 0);
        vm.stopPrank();
    }

    function test_GlobalRateLimit_Exceeded_Reverts() public {
        // Unpause rate limiting for this test
        vm.prank(owner);
        stableGuard.setRateLimitingPause(false);

        // Use unique users and ETH deposits so per-user limits aren't hit
        uint256 depositAmount = 50 ether;
        uint256 mintAmount = 25 ether;

        // Ensure initial timestamp exceeds cooldown for first-time users
        vm.warp(block.timestamp + 5 minutes + 1);

        // Log initial global rate limit state
        RateLimiter.GlobalRateLimit memory grlStart = stableGuard.getGlobalRateLimit();
        console.log("[GlobalRL] start ts:", block.timestamp);
        console.log("[GlobalRL] windowStart:", uint256(grlStart.globalWindowStart));
        console.log("[GlobalRL] opCount:", uint256(grlStart.globalOperationCount));
        console.log("[GlobalRL] volume:", uint256(grlStart.globalVolumeInWindow));

        // Perform 1000 distinct operations within the global window
        vm.pauseGasMetering();
        for (uint256 i = 0; i < 1000; i++) {
            address addr = address(uint160(0x1000 + i));
            vm.deal(addr, depositAmount);
            vm.prank(addr);
            stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, mintAmount);
            if (i % 200 == 0) {
                RateLimiter.GlobalRateLimit memory grlMid = stableGuard.getGlobalRateLimit();
                console.log("[GlobalRL] after", i + 1, "ops, ts:", block.timestamp);
                console.log("[GlobalRL] opCount:", uint256(grlMid.globalOperationCount));
                console.log("[GlobalRL] volume:", uint256(grlMid.globalVolumeInWindow));
            }
        }
        vm.resumeGasMetering();

        // Log state before final revert attempt
        RateLimiter.GlobalRateLimit memory grlAfter = stableGuard.getGlobalRateLimit();
        console.log("[GlobalRL] after 1000 ops ts:", block.timestamp);
        console.log("[GlobalRL] windowStart:", uint256(grlAfter.globalWindowStart));
        console.log("[GlobalRL] opCount:", uint256(grlAfter.globalOperationCount));
        console.log("[GlobalRL] volume:", uint256(grlAfter.globalVolumeInWindow));

        // 1001st operation should exceed globalMaxOps and revert
        address addrFail = address(uint160(0x1000 + 1000));
        vm.deal(addrFail, depositAmount);
        console.log("[GlobalRL] attempting 1001st op ts:", block.timestamp);
        vm.expectRevert("Global rate limit exceeded");
        vm.prank(addrFail);
        stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, mintAmount);
    }

    function test_BurnAndWithdraw_Success() public {
        // Setup: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Set total collateral value to reflect deposit value ($200)
        collateralManager.setTotalCollateralValue(user, 200e18);

        // Burn 50, withdraw 50 => remains safe (150/50 = 300%)
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 50e18, 50e18);

        StableGuard.UserPosition memory pos = stableGuard.getUserPosition(user);
        assertEq(pos.debt, 50e18);
        assertEq(collateralManager.getUserCollateral(user, address(mockToken)), 150e18);
        assertEq(stableGuard.balanceOf(user), 50e18);
        // Strict forward: user should receive the 50 collateral tokens
        assertEq(mockToken.balanceOf(user), 50e18);
    }

    function test_BurnAndWithdraw_RevertWhileCollateralInAuction() public {
        // Setup: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();
        collateralManager.setTotalCollateralValue(user, 200e18);

        // An active auction on this token blocks withdrawals
        auctionManager.setUserTokenAuction(user, address(mockToken), 7);

        vm.prank(user);
        vm.expectRevert("Collateral in auction");
        stableGuard.burnAndWithdraw(address(mockToken), 50e18, 50e18);

        // Once the auction clears, the withdrawal succeeds
        auctionManager.setUserTokenAuction(user, address(mockToken), 0);
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 50e18, 50e18);
    }

    function test_LiquidatePosition_ERC20_ForwardsToLiquidator_Success() public {
        // Setup: position with ERC20 collateral and debt
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Make the position liquidatable (below the 120% threshold)
        collateralManager.setTotalCollateralValue(user, 110e18);

        // The liquidator needs stablecoins to cover the debt
        // Transfer 60 SGD from the user to the liquidator and approve
        vm.prank(user);
        bool ok1 = stableGuard.transfer(liquidator, 60e18);
        assertTrue(ok1, "ERC20 transfer failed");
        vm.prank(liquidator);
        bool ok2 = stableGuard.approve(address(stableGuard), 60e18);
        assertTrue(ok2, "ERC20 approve failed");

        // Liquidate 60 directly: requires forwarding 66 (10% bonus)
        vm.prank(liquidator);
        stableGuard.liquidatePosition(user, address(mockToken), 60e18);

        // Verify: reduced debt, reduced collateral, and liquidator receives tokens
        StableGuard.UserPosition memory pos = stableGuard.getUserPosition(user);
        assertEq(pos.debt, 40e18);
        assertEq(collateralManager.getUserCollateral(user, address(mockToken)), 134e18);
        assertEq(mockToken.balanceOf(liquidator), 66e18);
    }

    function test_Liquidate_AutoToken_Success() public {
        // Create a position: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Now make position unsafe for liquidation: set collateral value below 120% of debt
        collateralManager.setTotalCollateralValue(user, 110e18); // debt=100 => 110% < 120%

        // Configure optimal token
        liquidationManager.setOptimalToken(address(mockToken));

        // Liquidator triggers
        vm.prank(liquidator);
        uint256 auctionId = stableGuard.liquidate(user, 50e18);
        assertEq(auctionId, 1);
    }

    function test_Liquidate_SpecificToken_Success() public {
        // Position safe initially
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Unsafe for liquidation
        collateralManager.setTotalCollateralValue(user, 110e18);

        vm.prank(liquidator);
        uint256 auctionId = stableGuard.liquidate(user, address(mockToken), 60e18);
        assertEq(auctionId, 1);
    }

    function test_EmergencyLiquidate_OnlyOwner_Succeeds() public {
        // Setup position
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Fund the CollateralManager so it can pay out the seized collateral
        mockToken.mint(address(collateralManager), depositAmount);

        // Owner sources 50 SGD and approves StableGuard to pull them
        vm.prank(user);
        stableGuard.transfer(owner, 50e18);

        uint256 supplyBefore = stableGuard.totalSupply();
        uint256 ownerTokensBefore = mockToken.balanceOf(owner);

        vm.startPrank(owner);
        stableGuard.approve(address(stableGuard), 50e18);
        stableGuard.emergencyLiquidate(user, address(mockToken), 50e18);
        vm.stopPrank();

        // Exactly one debt decrement, one burn, and equivalent collateral seized
        StableGuard.UserPosition memory pos = stableGuard.getUserPosition(user);
        assertEq(pos.debt, 50e18);
        assertEq(stableGuard.totalSupply(), supplyBefore - 50e18);
        // mockToken is priced at $1 with 18 decimals -> $50 = 50 tokens
        assertEq(mockToken.balanceOf(owner), ownerTokensBefore + 50e18);
        assertEq(collateralManager.getUserCollateral(user, address(mockToken)), depositAmount - 50e18);
    }

    function test_ProcessAuctionCompletion_UpdatesDebt() public {
        // Setup position
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Give StableGuard contract tokens to burn
        vm.prank(user);
        bool okTransfer3 = stableGuard.transfer(address(stableGuard), 40e18);
        assertTrue(okTransfer3, "ERC20 transfer failed");

        // Only auction manager can call
        vm.prank(address(auctionManager));
        stableGuard.processAuctionCompletion(user, 40e18);

        StableGuard.UserPosition memory pos = stableGuard.getUserPosition(user);
        assertEq(pos.debt, 60e18);
    }

    // =====================
    // Additional Rate Limiting & Edge Case Tests
    // =====================

    function test_RateLimit_VolumeExceeded_Deposit_Reverts() public {
        // Unpause rate limiting for this test
        vm.prank(owner);
        stableGuard.setRateLimitingPause(false);
        // Large ETH deposit exceeding MAX_VOLUME_PER_HOUR (100000 ether)
        uint256 depositAmount = 100001 ether;
        uint256 mintAmount = 1e18; // small debt to keep position safe
        collateralManager.setTotalCollateralValue(user, 0);
        vm.deal(user, depositAmount);

        vm.expectRevert("Rate limit exceeded");
        vm.prank(user);
        stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, mintAmount);
    }

    function test_RateLimit_Cooldown_Enforced() public {
        // Unpause rate limiting for this test
        vm.prank(owner);
        stableGuard.setRateLimitingPause(false);
        // Setup a large position to allow many small ops
        uint256 depositAmount = 1000e18;
        uint256 mintAmount = 500e18; // 200% ratio
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();
        // Reflect collateral value to prevent underflow on withdraw
        collateralManager.setTotalCollateralValue(user, depositAmount);

        // Add initial warp to clear cooldown from previous deposit operation
        vm.warp(block.timestamp + 5 minutes + 1);

        // First small burn/withdraw succeeds
        console.log("[Cooldown] t0 (after initial warp):", block.timestamp);
        RateLimiter.RateLimitData memory before1 = stableGuard.getUserRateLimit(user);
        console.log("[Cooldown] before1 lastOp:", uint256(before1.lastOperationTime));
        console.log("[Cooldown] before1 burst:", uint256(before1.burstCount));
        console.log("[Cooldown] before1 opCount:", uint256(before1.operationCount));
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);
        RateLimiter.RateLimitData memory after1 = stableGuard.getUserRateLimit(user);
        console.log("[Cooldown] after1 lastOp:", uint256(after1.lastOperationTime));
        console.log("[Cooldown] after1 burst:", uint256(after1.burstCount));
        console.log("[Cooldown] after1 opCount:", uint256(after1.operationCount));

        // Immediate second operation should hit cooldown (5 minutes)
        console.log("[Cooldown] t1:", block.timestamp);
        RateLimiter.RateLimitData memory before2 = stableGuard.getUserRateLimit(user);
        console.log("[Cooldown] before2 lastOp:", uint256(before2.lastOperationTime));
        console.log("[Cooldown] before2 burst:", uint256(before2.burstCount));
        console.log("[Cooldown] before2 opCount:", uint256(before2.operationCount));
        vm.expectRevert("Rate limit exceeded");
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);

        // After cooldown period, operation succeeds (warp full cooldown)
        vm.warp(block.timestamp + 5 minutes + 1);
        console.log("[Cooldown] t2 (after warp):", block.timestamp);
        RateLimiter.RateLimitData memory before3 = stableGuard.getUserRateLimit(user);
        console.log("[Cooldown] before3 lastOp:", uint256(before3.lastOperationTime));
        console.log("[Cooldown] before3 burst:", uint256(before3.burstCount));
        console.log("[Cooldown] before3 opCount:", uint256(before3.operationCount));
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);
        RateLimiter.RateLimitData memory after3 = stableGuard.getUserRateLimit(user);
        console.log("[Cooldown] after3 lastOp:", uint256(after3.lastOperationTime));
        console.log("[Cooldown] after3 burst:", uint256(after3.burstCount));
        console.log("[Cooldown] after3 opCount:", uint256(after3.operationCount));
    }

    function test_RateLimit_MaxOperationsPerHour_RevertsOn11th() public {
        //  Unpause rate limiting for this test
        vm.prank(owner);
        stableGuard.setRateLimitingPause(false);
        // Setup a large position to allow many small ops
        uint256 depositAmount = 10000e18;
        uint256 mintAmount = 5000e18; // 200% ratio
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();
        // Reflect collateral value to prevent underflow on withdraw
        collateralManager.setTotalCollateralValue(user, depositAmount);

        // Advance time to avoid cooldown before next operation
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);

        // Immediate second operation should hit cooldown (5 minutes)
        vm.expectRevert("Rate limit exceeded");
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);

        // After cooldown period, operation succeeds (warp full cooldown)
        vm.warp(block.timestamp + 5 minutes + 1);

        // Reset user rate limit to start max-ops counting fresh
        vm.prank(owner);
        stableGuard.resetUserRateLimit(user);

        // Perform 10 operations, spaced by cooldown, within 1 hour window
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user);
            stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);
            RateLimiter.RateLimitData memory rl = stableGuard.getUserRateLimit(user);
            console.log("[UserRL-MAXOPS] op", i + 1, "ts:", block.timestamp);
            console.log("[UserRL-MAXOPS] opCount:", uint256(rl.operationCount));
            console.log("[UserRL-MAXOPS] burstCount:", uint256(rl.burstCount));
            console.log("[UserRL-MAXOPS] lastOp:", uint256(rl.lastOperationTime));
            // Space operations by cooldown and ensure burst window resets
            vm.warp(block.timestamp + 5 minutes + 1);
        }

        // 11th operation within the same hour should exceed MAX_OPERATIONS_PER_HOUR
        RateLimiter.RateLimitData memory rlBefore11 = stableGuard.getUserRateLimit(user);
        console.log("[UserRL-MAXOPS] before 11th op ts:", block.timestamp);
        console.log("[UserRL-MAXOPS] opCount:", uint256(rlBefore11.operationCount));
        console.log("[UserRL-MAXOPS] burstCount:", uint256(rlBefore11.burstCount));
        vm.expectRevert("Rate limit exceeded");
        // Still within the same hour window
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);
    }

    function test_RateLimit_Pause_Allows_UnsafeVolume() public {
        // Pause rate limiting
        vm.prank(owner);
        stableGuard.setRateLimitingPause(true);

        // Attempt an oversized deposit which would normally exceed MAX_VOLUME_PER_HOUR
        uint256 depositAmount = 100001 ether;
        uint256 mintAmount = 1e18;
        collateralManager.setTotalCollateralValue(user, 0);
        vm.deal(user, depositAmount);

        vm.prank(user);
        stableGuard.depositAndMint{value: depositAmount}(Constants.ETH_TOKEN, depositAmount, mintAmount);

        // Confirm mint succeeded
        assertEq(stableGuard.balanceOf(user), mintAmount);
    }

    // Repeg config changes are governance actions, routed through the Timelock
    function test_Repeg_Admin_UpdateConfig_OnlyTimelock_AndEffect() public {
        IRepegManager.RepegConfig memory newCfg = IRepegManager.RepegConfig({
            targetPrice: 1e18,
            deviationThreshold: 777,
            repegCooldown: 3600,
            arbitrageWindow: 600,
            incentiveRate: 555,
            maxRepegPerDay: 5,
            enabled: true
        });

        // Even the owner cannot call it directly — it must come from the Timelock
        vm.expectRevert("Only timelock");
        vm.prank(owner);
        stableGuard.updateRepegConfig(newCfg);

        vm.expectRevert("Only timelock");
        vm.prank(address(0x444));
        stableGuard.updateRepegConfig(newCfg);

        // The Timelock updates config
        vm.prank(timelock);
        stableGuard.updateRepegConfig(newCfg);

        IRepegManager.RepegConfig memory readCfg = stableGuard.getRepegConfig();
        assertEq(readCfg.deviationThreshold, 777);
        assertEq(readCfg.incentiveRate, 555);
    }

    function test_Repeg_Admin_SetEmergencyPause_OnlyOwner_AndEffect() public {
        // Non-owner cannot pause
        vm.expectRevert("Only owner");
        vm.prank(address(0x555));
        stableGuard.setRepegEmergencyPause(true);

        // Owner pauses operations
        vm.prank(owner);
        stableGuard.setRepegEmergencyPause(true);

        // Liquidity provision (now direct on the RepegManager) reverts while paused
        vm.expectRevert("paused");
        repegManager.provideLiquidity(1000);

        // Owner unpauses operations
        vm.prank(owner);
        stableGuard.setRepegEmergencyPause(false);

        // Liquidity provision should succeed
        bool ok = repegManager.provideLiquidity(500);
        assertTrue(ok);
    }

    function test_UpdateModules_Success_UsesNewRepeg() public {
        // Deploy new mocks
        MockPriceOracle priceOracle2 = new MockPriceOracle();
        MockCollateralManager collateralManager2 = new MockCollateralManager();
        MockLiquidationManager liquidationManager2 = new MockLiquidationManager();
        MockDutchAuctionManager auctionManager2 = new MockDutchAuctionManager();
        MockRepegManager repegManager2 = new MockRepegManager();

        // Configure new repeg manager with different target price
        IRepegManager.RepegConfig memory cfg2 = IRepegManager.RepegConfig({
            targetPrice: 2e18,
            deviationThreshold: 800,
            repegCooldown: 7200,
            arbitrageWindow: 900,
            incentiveRate: 120,
            maxRepegPerDay: 3,
            enabled: true
        });
        repegManager2.updateRepegConfig(cfg2);

        // Update modules (via Timelock)
        vm.prank(timelock);
        stableGuard.updateModules(
            address(priceOracle2),
            address(collateralManager2),
            address(liquidationManager2),
            address(auctionManager2),
            address(repegManager2)
        );

        // Verify StableGuard now uses new repeg manager by reading its config
        IRepegManager.RepegConfig memory readCfg = stableGuard.getRepegConfig();
        assertEq(readCfg.targetPrice, 2e18);
        assertEq(readCfg.deviationThreshold, 800);
    }

    function test_Repeg_Getters() public view {
        IRepegManager.RepegConfig memory cfg = stableGuard.getRepegConfig();
        assertTrue(cfg.enabled);
        IRepegManager.RepegState memory st = stableGuard.getRepegState();
        assertEq(st.currentPrice, 1e18);
        (uint256 tl, uint256 al) = stableGuard.getRepegLiquidityStatus();
        assertEq(tl, 0);
        assertEq(al, 0);
    }

    function test_Repeg_StatusAndTrigger() public {
        (bool needed, uint128 deviation) = stableGuard.checkRepegStatus();
        assertTrue(needed);
        assertEq(deviation, 100);
        (bool triggered, uint128 newPrice) = stableGuard.triggerRepeg();
        assertTrue(triggered);
        assertEq(newPrice, 1e18);
    }

    function test_Repeg_LiquidityProvideWithdraw() public {
        // Liquidity flows directly through the RepegManager so the provider is
        // credited correctly; StableGuard only exposes the read-side status.
        bool ok = repegManager.provideLiquidity(1000);
        assertTrue(ok);
        (uint256 tl, uint256 al) = stableGuard.getRepegLiquidityStatus();
        assertEq(tl, 1000);
        assertEq(al, 1000);
        ok = repegManager.withdrawLiquidity(400);
        assertTrue(ok);
        (tl, al) = stableGuard.getRepegLiquidityStatus();
        assertEq(tl, 600);
        assertEq(al, 600);
    }

    function test_Repeg_ArbitrageOps() public {
        IRepegManager.ArbitrageOpportunity[] memory opps = stableGuard.getArbitrageOpportunities();
        assertEq(opps.length, 1);
        uint128 profit = stableGuard.executeArbitrage(10000, 50);
        assertEq(profit, uint128(100));
    }

    function test_Repeg_CalculateIncentive() public {
        uint128 inc = stableGuard.calculateRepegIncentive(address(this));
        assertEq(inc, 10);
    }

    function test_RateLimit_AdminFunctions() public {
        stableGuard.setRateLimitingPause(true);
        stableGuard.resetUserRateLimit(user);
        stableGuard.resetGlobalRateLimit();
        bool allowed = stableGuard.checkRateLimitStatus(user, "DEPOSIT", 0);
        assertTrue(allowed);
    }

    function test_RateLimit_ResetUserRateLimit_ClearsCounters() public {
        // Unpause rate limiting for this test
        vm.prank(owner);
        stableGuard.setRateLimitingPause(false);
        // Setup and perform an operation to populate counters
        uint256 depositAmount = 1000e18;
        uint256 mintAmount = 500e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();
        // Reflect collateral value to prevent underflow on withdraw
        collateralManager.setTotalCollateralValue(user, depositAmount);

        // Advance time to avoid cooldown before next operation
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 1e18);

        // Verify counters updated
        RateLimiter.RateLimitData memory beforeData = stableGuard.getUserRateLimit(user);
        assertGt(beforeData.operationCount, 0);
        assertGt(beforeData.volumeInWindow, 0);

        // Reset (owner only)
        vm.prank(owner);
        stableGuard.resetUserRateLimit(user);

        RateLimiter.RateLimitData memory afterData = stableGuard.getUserRateLimit(user);
        assertEq(afterData.operationCount, 0);
        assertEq(afterData.volumeInWindow, 0);
        assertEq(afterData.lastOperationTime, 0);
    }

    function test_RateLimit_AdminOnlyFunctions_RevertForNonOwner() public {
        vm.expectRevert("Only owner");
        vm.prank(address(0x444));
        stableGuard.setRateLimitingPause(true);

        vm.expectRevert("Only owner");
        vm.prank(address(0x444));
        stableGuard.resetUserRateLimit(user);

        vm.expectRevert("Only owner");
        vm.prank(address(0x444));
        stableGuard.resetGlobalRateLimit();
    }

    function test_CollateralThreshold_ExactBoundary_Succeeds() public {
        // minCollateralRatio = 15000 (150%) by default
        uint256 depositAmount = 150e18; // $150
        uint256 mintAmount = 100e18; // $100 debt
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        assertEq(stableGuard.balanceOf(user), mintAmount);
    }

    function test_CollateralThreshold_JustBelowBoundary_Reverts() public {
        uint256 depositAmount = 149e18; // $149 < 150% of $100
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        vm.expectRevert("Insufficient collateral");
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();
    }

    function test_Liquidate_PositionSafe_AtThreshold_Reverts() public {
        // Setup position
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Set collateral value to exactly 120% of debt (liquidationThreshold=12000)
        collateralManager.setTotalCollateralValue(user, 120e18);

        vm.expectRevert("Position safe");
        vm.prank(liquidator);
        stableGuard.liquidate(user, 50e18);
    }

    function test_BurnAndWithdraw_UnsafeFinalPosition_Reverts() public {
        // Setup: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Reflect collateral value ($200)
        collateralManager.setTotalCollateralValue(user, 200e18);

        // Burn a small amount and attempt to withdraw too much -> unsafe
        vm.expectRevert("Unsafe final position");
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 1e18, 160e18);
    }

    function test_BurnAndWithdraw_RevertsOnInsufficientDebt() public {
        // Setup: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Try to burn more than current debt (assembly revert selector)
        vm.expectRevert(bytes4(0x356680b7)); // "Insufficient debt"
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 150e18, 50e18);
    }

    function test_BurnAndWithdraw_RevertsOnInsufficientCollateral() public {
        // Setup: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Withdraw more than collateral
        vm.expectRevert("Insufficient collateral");
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 10e18, 250e18);
    }

    function test_BurnAndWithdraw_RevertsOnInsufficientBalance() public {
        // Setup: deposit 200, mint 100
        uint256 depositAmount = 200e18;
        uint256 mintAmount = 100e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Transfer away user's stable token balance
        vm.prank(user);
        bool okTransfer4 = stableGuard.transfer(address(0x555), 100e18);
        assertTrue(okTransfer4, "ERC20 transfer failed");

        vm.expectRevert("Insufficient balance");
        vm.prank(user);
        stableGuard.burnAndWithdraw(address(mockToken), 10e18, 10e18);
    }

    function test_UpdateModules_DuplicateAddresses_Revert() public {
        // priceOracle == collateralManager to trigger duplicate address revert
        vm.expectRevert("Duplicate module addresses");
        vm.prank(timelock);
        stableGuard.updateModules(
            address(priceOracle), address(priceOracle), address(liquidationManager), address(auctionManager), repeg
        );
    }

    function test_UpdateModules_OnlyTimelock_RevertOtherwise() public {
        // The owner cannot bypass the Timelock
        vm.expectRevert("Only timelock");
        vm.prank(owner);
        stableGuard.updateModules(
            address(priceOracle),
            address(collateralManager),
            address(liquidationManager),
            address(auctionManager),
            repeg
        );

        vm.expectRevert("Only timelock");
        vm.prank(address(0x444));
        stableGuard.updateModules(
            address(priceOracle),
            address(collateralManager),
            address(liquidationManager),
            address(auctionManager),
            repeg
        );
    }

    function test_CheckRateLimitStatus_ViewReflectsCooldown() public {
        // Unpause rate limiting for this test
        vm.prank(owner);
        stableGuard.setRateLimitingPause(false);
        // Setup and perform one operation
        uint256 depositAmount = 500e18;
        uint256 mintAmount = 200e18;
        collateralManager.setTotalCollateralValue(user, 0);
        mockToken.mint(user, depositAmount);
        vm.startPrank(user);
        mockToken.approve(address(stableGuard), depositAmount);
        stableGuard.depositAndMint(address(mockToken), depositAmount, mintAmount);
        vm.stopPrank();

        // Immediately check status for another operation of small volume
        bool allowed = stableGuard.checkRateLimitStatus(user, "WITHDRAW", 1e18);
        assertEq(allowed, false);

        // After cooldown, should be allowed
        vm.warp(block.timestamp + 5 minutes);
        allowed = stableGuard.checkRateLimitStatus(user, "WITHDRAW", 1e18);
        assertEq(allowed, true);
    }
}

// =====================
// Governance via Timelock (end-to-end with the real Timelock)
// =====================

contract StableGuardTimelockTest is Test {
    StableGuard public stableGuard;
    Timelock public timelock;
    MockPriceOracle public priceOracle;
    MockCollateralManager public collateralManager;
    MockLiquidationManager public liquidationManager;
    MockDutchAuctionManager public auctionManager;
    MockRepegManager public repegManager;

    address public deployer = address(this); // owner of the Timelock

    function setUp() public {
        vm.warp(1_000_000);

        priceOracle = new MockPriceOracle();
        collateralManager = new MockCollateralManager();
        liquidationManager = new MockLiquidationManager();
        auctionManager = new MockDutchAuctionManager();
        repegManager = new MockRepegManager();

        // Deployer owns the Timelock; StableGuard is wired to it
        timelock = new Timelock(2 days);
        stableGuard = new StableGuard(
            address(priceOracle),
            address(collateralManager),
            address(liquidationManager),
            address(auctionManager),
            address(repegManager),
            address(timelock)
        );
    }

    function test_UpdateConfig_ExecutesThroughTimelockAfterDelay() public {
        // Queue updateConfig(16000, 13000, 11000) on StableGuard
        bytes memory data = abi.encode(uint64(16000), uint64(13000), uint32(11000));
        string memory sig = "updateConfig(uint64,uint64,uint32)";
        uint256 eta = block.timestamp + timelock.MINIMUM_DELAY();

        timelock.queueTransaction(address(stableGuard), 0, sig, data, eta);

        // Executing before the delay must revert
        vm.expectRevert(Timelock.TransactionNotReady.selector);
        timelock.executeTransaction(address(stableGuard), 0, sig, data, eta);

        // After the delay, it executes and the config actually changes
        vm.warp(eta);
        timelock.executeTransaction(address(stableGuard), 0, sig, data, eta);

        StableGuard.PackedConfig memory cfg = stableGuard.getSystemConfig();
        assertEq(cfg.minCollateralRatio, 16000);
        assertEq(cfg.liquidationThreshold, 13000);
        assertEq(cfg.emergencyThreshold, 11000);
    }

    function test_UpdateConfig_DirectByOwnerReverts() public {
        // The StableGuard OWNER (deployer) cannot call updateConfig directly
        vm.expectRevert("Only timelock");
        stableGuard.updateConfig(16000, 13000, 11000);
    }
}
