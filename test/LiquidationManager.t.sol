// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {LiquidationManager} from "../src/LiquidationManager.sol";
import {ILiquidationManager} from "../src/interfaces/ILiquidationManager.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ICollateralManager} from "../src/interfaces/ICollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LiquidationManager Test Suite
/// @dev The manager is a pure risk/calculation module: thresholds come from
///      StableGuard (mocked here) and no liquidation is executed by it.
contract LiquidationManagerTest is Test {
    // ============ CONTRACTS ============
    LiquidationManager public liquidationManager;
    MockPriceOracle public mockOracle;
    MockCollateralManager public mockCollateral;
    MockERC20 public mockToken;
    MockERC20 public mockWbtc;
    MockStableGuard public mockStableGuard;

    // ============ TEST ACCOUNTS ============
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    // ============ TEST CONSTANTS ============
    uint256 public constant TOKEN_PRICE = 2000e18; // $2000 per token
    uint256 public constant DEBT_AMOUNT = 1000e18; // $1000 debt
    uint256 public constant COLLATERAL_AMOUNT = 1e18; // 1 token

    // ============ SETUP ============
    function setUp() public {
        mockOracle = new MockPriceOracle();
        mockCollateral = new MockCollateralManager();
        mockToken = new MockERC20("Test Token", "TEST");
        mockWbtc = new MockERC20("Wrapped BTC", "WBTC");
        mockStableGuard = new MockStableGuard();

        vm.prank(owner);
        liquidationManager = new LiquidationManager(owner, address(mockOracle), address(mockCollateral));

        vm.prank(owner);
        liquidationManager.setStableGuard(address(mockStableGuard));

        // 18-decimal token at $2000
        mockOracle.setTokenPrice(address(mockToken), TOKEN_PRICE);
        mockOracle.setTokenDecimals(address(mockToken), 18);
        mockOracle.addSupportedToken(address(mockToken));

        // 8-decimal token at $30000 (exercises decimal-aware math)
        mockOracle.setTokenPrice(address(mockWbtc), 30000e18);
        mockOracle.setTokenDecimals(address(mockWbtc), 8);
        mockOracle.addSupportedToken(address(mockWbtc));

        mockCollateral.setUserCollateral(user, address(mockToken), COLLATERAL_AMOUNT);
        mockCollateral.setTotalCollateralValue(user, TOKEN_PRICE); // $2000 collateral

        mockStableGuard.setUserDebt(user, DEBT_AMOUNT); // $1000 debt
    }

    // ============ WIRING TESTS ============

    function test_Constructor() public {
        LiquidationManager newManager = new LiquidationManager(owner, address(mockOracle), address(mockCollateral));
        assertEq(newManager.stableGuard(), address(0));

        // Without a StableGuard wired, config reads revert (no silent fallbacks)
        vm.expectRevert(ILiquidationManager.InvalidAddress.selector);
        newManager.getConfig();
    }

    function test_Constructor_RevertZeroAddresses() public {
        vm.expectRevert();
        new LiquidationManager(address(0), address(mockOracle), address(mockCollateral));

        vm.expectRevert();
        new LiquidationManager(owner, address(0), address(mockCollateral));

        vm.expectRevert();
        new LiquidationManager(owner, address(mockOracle), address(0));
    }

    function test_SetStableGuard() public {
        // Thresholds are read straight from StableGuard: the single source of truth
        (address stableGuard, uint32 minRatio, uint32 liqThreshold, uint32 bonus) = liquidationManager.getConfig();
        assertEq(stableGuard, address(mockStableGuard));
        assertEq(minRatio, 15000);
        assertEq(liqThreshold, 12000);
        assertEq(bonus, 1000);

        // Changing StableGuard's config changes what the manager reports
        mockStableGuard.setSystemConfig(16000, 13000, 11000, 500);
        (, minRatio, liqThreshold, bonus) = liquidationManager.getConfig();
        assertEq(minRatio, 16000);
        assertEq(liqThreshold, 13000);
        assertEq(bonus, 500);
    }

    function test_SetStableGuard_RevertUnauthorized() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        liquidationManager.setStableGuard(makeAddr("newGuard"));
    }

    function test_SetStableGuard_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ILiquidationManager.InvalidAddress.selector);
        liquidationManager.setStableGuard(address(0));
    }

    function test_NoDebtFallback_Removed() public {
        // A manager without StableGuard must revert, not report a magic 1000e18 debt
        LiquidationManager fresh = new LiquidationManager(owner, address(mockOracle), address(mockCollateral));
        mockCollateral.setTotalCollateralValue(user, TOKEN_PRICE);
        vm.expectRevert(ILiquidationManager.InvalidAddress.selector);
        fresh.isLiquidatable(user);
    }

    // ============ RISK ASSESSMENT TESTS ============

    function test_IsLiquidatable_True() public {
        // $1000 collateral vs $1000 debt -> ratio 100% < 120% threshold
        mockCollateral.setTotalCollateralValue(user, 1000e18);
        assertTrue(liquidationManager.isLiquidatable(user));
    }

    function test_IsLiquidatable_False() public {
        // $2000 collateral vs $1000 debt -> ratio 200% >= 120%
        assertFalse(liquidationManager.isLiquidatable(user));
    }

    function test_IsLiquidatable_ZeroAddress() public {
        assertFalse(liquidationManager.isLiquidatable(address(0)));
    }

    function test_IsLiquidatable_NoCollateral() public {
        mockCollateral.setTotalCollateralValue(user, 0);
        assertFalse(liquidationManager.isLiquidatable(user));
    }

    function test_GetCollateralRatio() public {
        // $2000 collateral / $1000 debt = 200% = 20000 bps
        assertEq(liquidationManager.getCollateralRatio(user), 20000);
    }

    function test_GetCollateralRatio_ZeroDebt() public {
        mockStableGuard.setUserDebt(user, 0);
        assertEq(liquidationManager.getCollateralRatio(user), type(uint256).max);
    }

    function test_GetCollateralRatio_ZeroAddress() public {
        assertEq(liquidationManager.getCollateralRatio(address(0)), 0);
    }

    function test_IsPositionSafe() public view {
        // 160% >= 150% (minRatio)
        assertTrue(liquidationManager.isPositionSafe(user, 1600e18, true));
        // 140% < 150% (minRatio)
        assertFalse(liquidationManager.isPositionSafe(user, 1400e18, true));
        // 140% >= 120% (liqThreshold)
        assertTrue(liquidationManager.isPositionSafe(user, 1400e18, false));
        // 110% < 120% (liqThreshold)
        assertFalse(liquidationManager.isPositionSafe(user, 1100e18, false));
    }

    function test_IsPositionSafe_ZeroAddress() public view {
        assertFalse(liquidationManager.isPositionSafe(address(0), 1600e18, true));
    }

    function test_IsPositionSafe_ZeroCollateral() public view {
        assertFalse(liquidationManager.isPositionSafe(user, 0, true));
    }

    function test_IsPositionSafeForLiquidation() public {
        // 200% >= 120%
        assertTrue(liquidationManager.isPositionSafeForLiquidation(user));

        mockCollateral.setTotalCollateralValue(user, 1100e18); // 110% < 120%
        assertFalse(liquidationManager.isPositionSafeForLiquidation(user));
    }

    // ============ CONVERSION MATH TESTS ============

    function test_CalculateLiquidationAmounts() public {
        (uint256 collateralAmount, uint256 liquidationBonus) =
            liquidationManager.calculateLiquidationAmounts(user, address(mockToken), DEBT_AMOUNT);

        // $1000 * 1.10 / $2000 = 0.55 tokens (18 decimals)
        assertEq(collateralAmount, 0.55e18);
        assertEq(liquidationBonus, (collateralAmount * 1000) / 10000);
    }

    function test_CalculateLiquidationAmounts_DecimalAware() public {
        // $30000 debt on an 8-decimal token at $30000 -> 1.1 WBTC = 1.1e8 units
        (uint256 collateralAmount,) = liquidationManager.calculateLiquidationAmounts(user, address(mockWbtc), 30000e18);
        assertEq(collateralAmount, 1.1e8);
    }

    function test_CalculateLiquidationAmounts_RevertZeroPrice() public {
        vm.expectRevert(ILiquidationManager.InvalidAmount.selector);
        liquidationManager.calculateLiquidationAmounts(user, makeAddr("unknownToken"), DEBT_AMOUNT);
    }

    function test_CalculateCollateralFromDebt() public view {
        // $1200 * 120% / $2000 = 0.72 tokens
        uint256 result = liquidationManager.calculateCollateralFromDebt(1200e18, TOKEN_PRICE);
        assertEq(result, 0.72e18);
    }

    function test_CalculateCollateralFromDebt_ZeroDebt() public view {
        assertEq(liquidationManager.calculateCollateralFromDebt(0, TOKEN_PRICE), 0);
    }

    function test_CalculateCollateralFromDebt_ZeroPrice() public {
        vm.expectRevert(ILiquidationManager.InvalidAmount.selector);
        liquidationManager.calculateCollateralFromDebt(1200e18, 0);
    }

    function test_GetLiquidationConstants() public view {
        (uint256 minRatio, uint256 liqThreshold, uint256 bonus) = liquidationManager.getLiquidationConstants();
        assertEq(minRatio, 15000);
        assertEq(liqThreshold, 12000);
        assertEq(bonus, 1000);
    }

    // ============ TOKEN SELECTION TESTS ============

    function test_FindOptimalToken() public {
        assertEq(liquidationManager.findOptimalToken(user), address(mockToken));
    }

    function test_FindOptimalToken_PicksHighestValue() public {
        // 1 WBTC ($30000) beats 1 TEST ($2000)
        mockCollateral.setUserCollateral(user, address(mockWbtc), 1e8);
        assertEq(liquidationManager.findOptimalToken(user), address(mockWbtc));
    }

    function test_FindOptimalToken_NoCollateral() public {
        address emptyUser = makeAddr("emptyUser");
        vm.expectRevert(ILiquidationManager.NoCollateral.selector);
        liquidationManager.findOptimalToken(emptyUser);
    }

    function test_FindOptimalTokenForLiquidation() public {
        assertEq(liquidationManager.findOptimalTokenForLiquidation(user), address(mockToken));
    }

    function test_FindOptimalTokenForLiquidation_ZeroAddress() public {
        assertEq(liquidationManager.findOptimalTokenForLiquidation(address(0)), address(0));
    }

    // ============ FUZZ TESTS ============

    function testFuzz_CollateralRatioCalculations(uint256 collateralValue, uint256 debtValue) public {
        collateralValue = bound(collateralValue, 1e18, 1e30);
        debtValue = bound(debtValue, 1e18, 1e30);

        mockCollateral.setTotalCollateralValue(user, collateralValue);
        mockStableGuard.setUserDebt(user, debtValue);

        uint256 ratio = liquidationManager.getCollateralRatio(user);
        assertEq(ratio, (collateralValue * 10000) / debtValue);
    }

    function testFuzz_CalculateLiquidationAmounts(uint256 debtAmount, uint256 tokenPrice) public {
        debtAmount = bound(debtAmount, 1e6, 1e27);
        tokenPrice = bound(tokenPrice, 1e6, 1e27);

        mockOracle.setTokenPrice(address(mockToken), tokenPrice);

        (uint256 collateralAmount, uint256 liquidationBonus) =
            liquidationManager.calculateLiquidationAmounts(user, address(mockToken), debtAmount);

        assertEq(collateralAmount, (debtAmount * 11000 * 1e18) / (10000 * tokenPrice));
        assertEq(liquidationBonus, (collateralAmount * 1000) / 10000);
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public tokenPrices;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => address) public priceFeeds;
    mapping(address => uint256) public fallbackPrices;
    mapping(address => bool) public supportedTokensMap;
    address[] public supportedTokens;

    function setTokenPrice(address token, uint256 price) external {
        tokenPrices[token] = price;
    }

    function setTokenDecimals(address token, uint8 decimals) external {
        tokenDecimals[token] = decimals;
    }

    function addSupportedToken(address token) external {
        if (!supportedTokensMap[token]) {
            supportedTokens.push(token);
            supportedTokensMap[token] = true;
        }
    }

    function getTokenPrice(address token) external view returns (uint256) {
        return tokenPrices[token];
    }

    function getTokenPriceWithEvents(address token) external returns (uint256) {
        uint256 price = tokenPrices[token];
        emit PriceUpdated(token, price, block.timestamp);
        return price;
    }

    function getTokenDecimals(address token) external view returns (uint8) {
        return tokenDecimals[token];
    }

    function getTokenValueInUsd(address token, uint256 amount) external view returns (uint256) {
        return (amount * tokenPrices[token]) / (10 ** tokenDecimals[token]);
    }

    function getTokenAmountFromUsd(address token, uint256 usdValue) external view returns (uint256) {
        return (usdValue * (10 ** tokenDecimals[token])) / tokenPrices[token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokensMap[token];
    }

    function configureToken(address token, address priceFeed, uint256 fallbackPrice, uint8 decimals) external {
        priceFeeds[token] = priceFeed;
        fallbackPrices[token] = fallbackPrice;
        tokenDecimals[token] = decimals;
        if (!supportedTokensMap[token]) {
            supportedTokens.push(token);
            supportedTokensMap[token] = true;
        }
        emit TokenConfigured(token, priceFeed, fallbackPrice, true);
    }

    function removeToken(address token) external {
        supportedTokensMap[token] = false;
        // Remove from array (simplified implementation)
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }
        emit TokenConfigured(token, address(0), 0, false);
    }

    function batchConfigureTokens(
        address[] calldata tokens,
        address[] calldata _priceFeeds,
        uint256[] calldata _fallbackPrices,
        uint8[] calldata decimals
    ) external {
        require(
            tokens.length == _priceFeeds.length && tokens.length == _fallbackPrices.length
                && tokens.length == decimals.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            this.configureToken(tokens[i], _priceFeeds[i], _fallbackPrices[i], decimals[i]);
        }
    }

    function getTokenConfig(address token)
        external
        view
        returns (address priceFeed, uint256 fallbackPrice, uint8 decimals)
    {
        return (priceFeeds[token], fallbackPrices[token], tokenDecimals[token]);
    }

    function getMultipleTokenPrices(address[] calldata tokens)
        external
        view
        returns (uint256[] memory prices, bool[] memory validFlags)
    {
        prices = new uint256[](tokens.length);
        validFlags = new bool[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            prices[i] = tokenPrices[tokens[i]];
            validFlags[i] = supportedTokensMap[tokens[i]];
        }
    }

    function checkFeedHealth(address token) external view returns (bool isHealthy, uint256 lastUpdate) {
        return (supportedTokensMap[token], block.timestamp);
    }

    function updateFallbackPrice(address token, uint256 newFallbackPrice) external {
        fallbackPrices[token] = newFallbackPrice;
        emit FallbackPriceUpdated(token, newFallbackPrice);
    }
}

contract MockCollateralManager is ICollateralManager {
    mapping(address => mapping(address => uint256)) public userCollateral;
    mapping(address => uint256) public totalCollateralValue;
    mapping(address => address[]) public userTokens;

    function setUserCollateral(address user, address token, uint256 amount) external {
        userCollateral[user][token] = amount;
    }

    function setTotalCollateralValue(address user, uint256 value) external {
        totalCollateralValue[user] = value;
    }

    function getUserCollateral(address user, address token) external view returns (uint256) {
        return userCollateral[user][token];
    }

    function getTotalCollateralValue(address user) external view returns (uint256) {
        return totalCollateralValue[user];
    }

    // Required interface implementations
    function addCollateralType(address, address, uint256, uint8) external {
        // Mock implementation - does nothing
    }

    function deposit(address user, address token, uint256 amount) external payable {
        userCollateral[user][token] += amount;
        // Add token to user's token list if not already present
        address[] storage tokens = userTokens[user];
        bool found = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                found = true;
                break;
            }
        }
        if (!found) {
            tokens.push(token);
        }
    }

    function withdraw(address user, address token, uint256 amount, address recipient) external {
        require(userCollateral[user][token] >= amount, "Insufficient collateral");
        userCollateral[user][token] -= amount;
        recipient; // Mock: no funds actually held
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function canLiquidate(address user, uint256 debtValue, uint256 liquidationThreshold) external view returns (bool) {
        uint256 collateralValue = totalCollateralValue[user];
        return collateralValue * 10000 < debtValue * liquidationThreshold;
    }

    function getCollateralRatio(
        address /* user */
    )
        external
        pure
        returns (uint256)
    {
        // Mock implementation - return a default ratio
        return 150; // 150%
    }

    function isCollateralSufficient(address user, uint256 debtAmount) external view returns (bool) {
        uint256 collateralValue = totalCollateralValue[user];
        return collateralValue >= debtAmount * 120 / 100; // 120% minimum ratio
    }

    function liquidateCollateral(
        address user,
        address,
        /* token */
        uint256 debtValue,
        uint256 liquidationThreshold
    )
        external
        view
        returns (bool)
    {
        uint256 collateralValue = totalCollateralValue[user];
        return collateralValue * 10000 < debtValue * liquidationThreshold;
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

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockStableGuard {
    mapping(address => uint256) public userDebt;

    uint64 public minCollateralRatio = 15000;
    uint64 public liquidationThreshold = 12000;
    uint32 public emergencyThreshold = 11000;
    uint32 public maxLiquidationBonus = 1000;

    function setUserDebt(address user, uint256 debt) external {
        userDebt[user] = debt;
    }

    function setSystemConfig(uint64 minRatio, uint64 liqThreshold, uint32 emergency, uint32 bonus) external {
        minCollateralRatio = minRatio;
        liquidationThreshold = liqThreshold;
        emergencyThreshold = emergency;
        maxLiquidationBonus = bonus;
    }

    function getDebt(address user) external view returns (uint256) {
        return userDebt[user];
    }

    function getSystemConfig() external view returns (uint64, uint64, uint32, uint32, uint32, uint32) {
        return (minCollateralRatio, liquidationThreshold, emergencyThreshold, maxLiquidationBonus, 3600, 0);
    }
}
