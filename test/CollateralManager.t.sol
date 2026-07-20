// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {ICollateralManager} from "../src/interfaces/ICollateralManager.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {Constants} from "../src/Constants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ============ MOCK CONTRACTS ============

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) private prices;
    mapping(address => bool) private supportedTokens;
    mapping(address => address) private priceFeeds;
    mapping(address => uint256) private fallbackPrices;
    mapping(address => uint8) private tokenDecimals;
    address[] private supportedTokensList;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        supportedTokens[token] = true;
    }

    function setSupportedToken(address token, bool supported) external {
        supportedTokens[token] = supported;
    }

    function setTokenDecimals(address token, uint8 decimals) external {
        tokenDecimals[token] = decimals;
    }

    // Core functions
    function getTokenPrice(address token) external view returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        return prices[token];
    }

    function getTokenPriceWithEvents(address token) external returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        uint256 price = prices[token];
        emit PriceUpdated(token, price, block.timestamp);
        return price;
    }

    function configureToken(address token, address priceFeed, uint256 fallbackPrice, uint8 decimals) external {
        bool isAdded = !supportedTokens[token];
        supportedTokens[token] = true;
        priceFeeds[token] = priceFeed;
        fallbackPrices[token] = fallbackPrice;
        tokenDecimals[token] = decimals;

        if (isAdded) {
            supportedTokensList.push(token);
        }

        emit TokenConfigured(token, priceFeed, fallbackPrice, isAdded);
    }

    function removeToken(address token) external {
        supportedTokens[token] = false;
        delete priceFeeds[token];
        delete fallbackPrices[token];
        delete tokenDecimals[token];
        delete prices[token];

        // Remove from array
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            if (supportedTokensList[i] == token) {
                supportedTokensList[i] = supportedTokensList[supportedTokensList.length - 1];
                supportedTokensList.pop();
                break;
            }
        }
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

    // View functions
    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokensList;
    }

    function getTokenValueInUsd(address token, uint256 amount) external view returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        uint256 price = prices[token];
        uint8 decimals = tokenDecimals[token];
        return (amount * price) / (10 ** decimals);
    }

    function getTokenAmountFromUsd(address token, uint256 usdValue) external view returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        return (usdValue * (10 ** tokenDecimals[token])) / prices[token];
    }

    function getTokenConfig(address token)
        external
        view
        returns (address priceFeed, uint256 fallbackPrice, uint8 decimals)
    {
        return (priceFeeds[token], fallbackPrices[token], tokenDecimals[token]);
    }

    function getTokenDecimals(address token) external view returns (uint8) {
        return tokenDecimals[token];
    }

    function getMultipleTokenPrices(address[] calldata tokens)
        external
        view
        returns (uint256[] memory _prices, bool[] memory validFlags)
    {
        _prices = new uint256[](tokens.length);
        validFlags = new bool[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (supportedTokens[tokens[i]]) {
                _prices[i] = prices[tokens[i]];
                validFlags[i] = true;
            } else {
                _prices[i] = 0;
                validFlags[i] = false;
            }
        }
    }

    function checkFeedHealth(address token) external view returns (bool isHealthy, uint256 lastUpdate) {
        isHealthy = supportedTokens[token];
        lastUpdate = block.timestamp;
    }

    function updateFallbackPrice(address token, uint256 newFallbackPrice) external {
        require(supportedTokens[token], "Token not supported");
        fallbackPrices[token] = newFallbackPrice;
        emit FallbackPriceUpdated(token, newFallbackPrice);
    }
}

contract MockStableGuard {
    CollateralManager public collateralManager;
    bool public attacking = false;
    address public attackUser;
    address public attackToken;
    uint256 public attackAmount;

    function setCollateralManager(address _collateralManager) external {
        collateralManager = CollateralManager(payable(_collateralManager));
    }

    function depositCollateral(address user, address token, uint256 amount) external payable {
        collateralManager.deposit{value: msg.value}(user, token, amount);
    }

    function withdrawCollateral(address user, address token, uint256 amount) external {
        collateralManager.withdraw(user, token, amount, address(this));
    }

    function startReentrancyAttack(address user, address token, uint256 amount) external {
        attacking = true;
        attackUser = user;
        attackToken = token;
        attackAmount = amount;

        // Start the attack
        collateralManager.withdraw(user, token, amount, address(this));
    }

    receive() external payable {
        if (attacking) {
            attacking = false; // Prevent infinite recursion
            // Try to reenter
            collateralManager.withdraw(attackUser, attackToken, attackAmount, address(this));
        }
    }
}

// ============ REENTRANCY ATTACKER ============

contract ReentrancyAttacker {
    CollateralManager public target;
    address public token;
    uint256 public amount;
    bool public attacking = false;

    constructor(address _target) {
        target = CollateralManager(payable(_target));
    }

    function attack(address _token, uint256 _amount) external {
        token = _token;
        amount = _amount;
        attacking = true;

        // Try to withdraw (this should trigger reentrancy)
        target.withdraw(address(this), token, amount, address(this));
    }

    // This will be called when ETH is sent to this contract
    receive() external payable {
        if (attacking && address(target).balance >= amount) {
            // Try to reenter
            target.withdraw(address(this), token, amount, address(this));
        }
    }
}

// ============ MAIN TEST CONTRACT ============

contract CollateralManagerTest is Test {
    CollateralManager public collateralManager;
    MockPriceOracle public priceOracle;
    MockStableGuard public stableGuard;
    MockERC20 public usdc;
    MockERC20 public wbtc;
    ReentrancyAttacker public attacker;

    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Test constants
    uint256 constant ETH_PRICE = 2000e18; // $2000
    uint256 constant USDC_PRICE = 1e18; // $1
    uint256 constant WBTC_PRICE = 30000e18; // $30000

    uint256 constant DEPOSIT_AMOUNT_ETH = 1 ether;
    uint256 constant DEPOSIT_AMOUNT_USDC = 1000e6; // 1000 USDC
    uint256 constant DEPOSIT_AMOUNT_WBTC = 1e8; // 1 WBTC

    // Events for testing
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);

    function setUp() public {
        // Setup accounts
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // Deploy mock contracts
        priceOracle = new MockPriceOracle();
        collateralManager = new CollateralManager(address(priceOracle));
        stableGuard = new MockStableGuard();

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // Setup price oracle
        priceOracle.setPrice(Constants.ETH_TOKEN, ETH_PRICE);
        priceOracle.setPrice(address(usdc), USDC_PRICE);
        priceOracle.setPrice(address(wbtc), WBTC_PRICE);

        priceOracle.setTokenDecimals(Constants.ETH_TOKEN, 18);
        priceOracle.setTokenDecimals(address(usdc), 6);
        priceOracle.setTokenDecimals(address(wbtc), 8);

        priceOracle.setSupportedToken(Constants.ETH_TOKEN, true);
        priceOracle.setSupportedToken(address(usdc), true);
        priceOracle.setSupportedToken(address(wbtc), true);

        // Set StableGuard
        collateralManager.setStableGuard(address(stableGuard));
        stableGuard.setCollateralManager(address(collateralManager));

        // Setup attacker contract
        attacker = new ReentrancyAttacker(address(collateralManager));

        // Fund accounts
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(address(stableGuard), 10 ether);
        vm.deal(address(attacker), 10 ether);

        // Mint tokens to users
        usdc.mint(user1, 10000e6);
        usdc.mint(user2, 10000e6);
        usdc.mint(address(stableGuard), 10000e6);

        wbtc.mint(user1, 10e8);
        wbtc.mint(user2, 10e8);
        wbtc.mint(address(stableGuard), 10e8);

        // Approve tokens
        vm.prank(user1);
        usdc.approve(address(collateralManager), type(uint256).max);
        vm.prank(user1);
        wbtc.approve(address(collateralManager), type(uint256).max);

        vm.prank(user2);
        usdc.approve(address(collateralManager), type(uint256).max);
        vm.prank(user2);
        wbtc.approve(address(collateralManager), type(uint256).max);

        vm.prank(address(stableGuard));
        usdc.approve(address(collateralManager), type(uint256).max);
        vm.prank(address(stableGuard));
        wbtc.approve(address(collateralManager), type(uint256).max);
    }

    // ============ CONSTRUCTOR & DEPLOYMENT TESTS ============

    function test_Constructor_Success() public {
        CollateralManager newManager = new CollateralManager(address(priceOracle));

        assertEq(newManager.owner(), address(this));
        assertEq(address(newManager.PRICE_ORACLE()), address(priceOracle));
        assertEq(newManager.stableGuard(), address(0));
    }

    function test_Constructor_RevertInvalidPriceOracle() public {
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        new CollateralManager(address(0));
    }

    // ============ ACCESS CONTROL TESTS ============

    function test_SetStableGuard_Success() public {
        address newStableGuard = makeAddr("newStableGuard");

        collateralManager.setStableGuard(newStableGuard);
        assertEq(collateralManager.stableGuard(), newStableGuard);
    }

    function test_SetStableGuard_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ICollateralManager.Unauthorized.selector);
        collateralManager.setStableGuard(makeAddr("newStableGuard"));
    }

    function test_SetStableGuard_RevertInvalidAddress() public {
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        collateralManager.setStableGuard(address(0));
    }

    // ============ COLLATERAL TYPE MANAGEMENT TESTS ============

    function test_AddCollateralType_Success() public {
        address newToken = makeAddr("newToken");
        address priceFeed = makeAddr("priceFeed");

        collateralManager.addCollateralType(
            newToken,
            priceFeed,
            1000e18, // fallbackPrice
            18 // decimals
        );

        (address token, address feed, uint256 fallbackPrice, uint8 decimals, bool isActive) =
            collateralManager.collateralTypes(newToken);

        assertEq(token, newToken);
        assertEq(feed, priceFeed);
        assertEq(fallbackPrice, 1000e18);
        assertEq(decimals, 18);
        assertTrue(isActive);
    }

    function test_AddCollateralType_RevertInvalidToken() public {
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        collateralManager.addCollateralType(address(0), makeAddr("priceFeed"), 1000e18, 18);
    }

    function test_AddCollateralType_RevertInvalidPriceFeed() public {
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        collateralManager.addCollateralType(makeAddr("token"), address(0), 1000e18, 18);
    }

    function test_AddCollateralType_RevertZeroFallbackPrice() public {
        vm.expectRevert(ICollateralManager.InvalidAmount.selector);
        collateralManager.addCollateralType(makeAddr("token"), makeAddr("priceFeed"), 0, 18);
    }

    function test_AddCollateralType_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ICollateralManager.Unauthorized.selector);
        collateralManager.addCollateralType(makeAddr("token"), makeAddr("priceFeed"), 1000e18, 18);
    }

    // ============ DEPOSIT TESTS ============

    function test_DepositETH_Success() public {
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        vm.prank(address(stableGuard));
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        assertEq(collateralManager.getUserCollateral(user1, Constants.ETH_TOKEN), DEPOSIT_AMOUNT_ETH);

        address[] memory userTokens = collateralManager.getUserTokens(user1);
        assertEq(userTokens.length, 1);
        assertEq(userTokens[0], Constants.ETH_TOKEN);
    }

    function test_DepositERC20_Success() public {
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, address(usdc), DEPOSIT_AMOUNT_USDC);

        vm.prank(address(stableGuard));
        collateralManager.deposit(user1, address(usdc), DEPOSIT_AMOUNT_USDC);

        assertEq(collateralManager.getUserCollateral(user1, address(usdc)), DEPOSIT_AMOUNT_USDC);

        address[] memory userTokens = collateralManager.getUserTokens(user1);
        assertEq(userTokens.length, 1);
        assertEq(userTokens[0], address(usdc));
    }

    function test_DepositETH_RevertETHMismatch() public {
        vm.prank(address(stableGuard));
        vm.expectRevert(ICollateralManager.ETHMismatch.selector);
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH - 1}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);
    }

    function test_DepositERC20_RevertETHMismatch() public {
        vm.prank(address(stableGuard));
        vm.expectRevert(ICollateralManager.ETHMismatch.selector);
        collateralManager.deposit{value: 1 ether}(user1, address(usdc), DEPOSIT_AMOUNT_USDC);
    }

    function test_Deposit_RevertUnsupportedToken() public {
        address unsupportedToken = makeAddr("unsupportedToken");

        vm.prank(address(stableGuard));
        vm.expectRevert(ICollateralManager.UnsupportedToken.selector);
        collateralManager.deposit(user1, unsupportedToken, 1000);
    }

    function test_Deposit_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ICollateralManager.Unauthorized.selector);
        collateralManager.deposit(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);
    }

    function test_Deposit_RevertInvalidUser() public {
        vm.prank(address(stableGuard));
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        collateralManager.deposit(address(0), Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);
    }

    function test_Deposit_RevertInvalidAmount() public {
        vm.prank(address(stableGuard));
        vm.expectRevert(ICollateralManager.InvalidAmount.selector);
        collateralManager.deposit(user1, Constants.ETH_TOKEN, 0);
    }

    // ============ WITHDRAW TESTS ============

    function test_WithdrawETH_Success() public {
        // First deposit
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        uint256 balanceBefore = address(stableGuard).balance;

        vm.expectEmit(true, true, false, true);
        emit Withdraw(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        vm.prank(address(stableGuard));
        collateralManager.withdraw(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH, address(stableGuard));

        assertEq(collateralManager.getUserCollateral(user1, Constants.ETH_TOKEN), 0);
        assertEq(address(stableGuard).balance, balanceBefore + DEPOSIT_AMOUNT_ETH);

        address[] memory userTokens = collateralManager.getUserTokens(user1);
        assertEq(userTokens.length, 0);
    }

    function test_WithdrawERC20_Success() public {
        // First deposit
        vm.prank(address(stableGuard));
        collateralManager.deposit(user1, address(usdc), DEPOSIT_AMOUNT_USDC);

        uint256 balanceBefore = usdc.balanceOf(address(stableGuard));

        vm.expectEmit(true, true, false, true);
        emit Withdraw(user1, address(usdc), DEPOSIT_AMOUNT_USDC);

        vm.prank(address(stableGuard));
        collateralManager.withdraw(user1, address(usdc), DEPOSIT_AMOUNT_USDC, address(stableGuard));

        assertEq(collateralManager.getUserCollateral(user1, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(stableGuard)), balanceBefore + DEPOSIT_AMOUNT_USDC);

        address[] memory userTokens = collateralManager.getUserTokens(user1);
        assertEq(userTokens.length, 0);
    }

    function test_Withdraw_RevertInsufficientCollateral() public {
        vm.prank(address(stableGuard));
        vm.expectRevert(ICollateralManager.InsufficientCollateral.selector);
        collateralManager.withdraw(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH, address(stableGuard));
    }

    function test_Withdraw_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ICollateralManager.Unauthorized.selector);
        collateralManager.withdraw(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH, address(stableGuard));
    }

    // ============ VIEW FUNCTIONS TESTS ============

    function test_GetTotalCollateralValue_Success() public {
        // Deposit multiple tokens
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        vm.prank(address(stableGuard));
        collateralManager.deposit(user1, address(usdc), DEPOSIT_AMOUNT_USDC);

        uint256 totalValue = collateralManager.getTotalCollateralValue(user1);

        // Expected: 1 ETH * $2000 + 1000 USDC (6 decimals) * $1 = $3000
        uint256 expectedValue = (DEPOSIT_AMOUNT_ETH * ETH_PRICE) / 1e18 + (DEPOSIT_AMOUNT_USDC * USDC_PRICE) / 1e6;

        assertEq(totalValue, expectedValue);
        assertEq(totalValue, 3000e18);
    }

    function test_GetTotalCollateralValue_EmptyUser() public {
        uint256 totalValue = collateralManager.getTotalCollateralValue(user1);
        assertEq(totalValue, 0);
    }

    function test_GetTotalCollateralValue_RevertInvalidUser() public {
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        collateralManager.getTotalCollateralValue(address(0));
    }

    function test_CanLiquidate_Success() public {
        // Deposit collateral
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        // Test case where user can be liquidated
        // Collateral value: 1 ETH * $2000 = $2000
        // Debt value: $1800, liquidation threshold: 120%
        // Required collateral: $1800 * 120% = $2160 > $2000 (can liquidate)
        bool canLiquidate = collateralManager.canLiquidate(user1, 1800e18, 12000);
        assertTrue(canLiquidate);

        // Test case where user cannot be liquidated
        // Debt value: $1500, liquidation threshold: 120%
        // Required collateral: $1500 * 120% = $1800 < $2000 (cannot liquidate)
        bool cannotLiquidate = collateralManager.canLiquidate(user1, 1500e18, 12000);
        assertFalse(cannotLiquidate);
    }

    function test_CanLiquidate_ZeroDebt() public {
        bool canLiquidate = collateralManager.canLiquidate(user1, 0, 12000);
        assertFalse(canLiquidate);
    }

    function test_CanLiquidate_RevertInvalidUser() public {
        vm.expectRevert(ICollateralManager.InvalidAddress.selector);
        collateralManager.canLiquidate(address(0), 1000e18, 12000);
    }

    function test_CanLiquidate_RevertInvalidThreshold() public {
        vm.expectRevert(ICollateralManager.InvalidAmount.selector);
        collateralManager.canLiquidate(user1, 1000e18, 0);

        vm.expectRevert(ICollateralManager.InvalidAmount.selector);
        collateralManager.canLiquidate(user1, 1000e18, 15001);
    }

    // ============ AUTHORIZED MANAGER TESTS ============

    function test_SetAuthorizedManager_Success() public {
        address manager = makeAddr("manager");
        collateralManager.setAuthorizedManager(manager, true);
        assertTrue(collateralManager.authorizedManagers(manager));

        collateralManager.setAuthorizedManager(manager, false);
        assertFalse(collateralManager.authorizedManagers(manager));
    }

    function test_SetAuthorizedManager_RevertNonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        collateralManager.setAuthorizedManager(unauthorized, true);
    }

    function test_SetStableGuard_AutoAuthorizes() public {
        // setUp wired the mock StableGuard; it must be able to move custody
        assertTrue(collateralManager.authorizedManagers(address(stableGuard)));
    }

    function test_Withdraw_PaysRecipientDirectly() public {
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        address manager = makeAddr("auctionManager");
        collateralManager.setAuthorizedManager(manager, true);

        uint256 balBefore = user2.balance;
        vm.prank(manager);
        collateralManager.withdraw(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH, user2);

        assertEq(user2.balance, balBefore + DEPOSIT_AMOUNT_ETH);
        assertEq(collateralManager.getUserCollateral(user1, Constants.ETH_TOKEN), 0);
    }

    function test_Withdraw_RevertUnauthorizedManager() public {
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: DEPOSIT_AMOUNT_ETH}(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH);

        vm.prank(unauthorized);
        vm.expectRevert(ICollateralManager.Unauthorized.selector);
        collateralManager.withdraw(user1, Constants.ETH_TOKEN, DEPOSIT_AMOUNT_ETH, unauthorized);
    }

    // ============ EMERGENCY FUNCTIONS TESTS ============

    function test_EmergencyWithdrawETH_Success() public {
        // Send some ETH to the contract
        vm.deal(address(collateralManager), 5 ether);

        uint256 balanceBefore = owner.balance;
        uint256 withdrawAmount = 2 ether;

        collateralManager.emergencyWithdraw(Constants.ETH_TOKEN, withdrawAmount);

        assertEq(owner.balance, balanceBefore + withdrawAmount);
        assertEq(address(collateralManager).balance, 5 ether - withdrawAmount);
    }

    function test_EmergencyWithdrawERC20_Success() public {
        // Send some tokens to the contract
        usdc.mint(address(collateralManager), 1000e6);

        uint256 balanceBefore = usdc.balanceOf(owner);
        uint256 withdrawAmount = 500e6;

        collateralManager.emergencyWithdraw(address(usdc), withdrawAmount);

        assertEq(usdc.balanceOf(owner), balanceBefore + withdrawAmount);
        assertEq(usdc.balanceOf(address(collateralManager)), 1000e6 - withdrawAmount);
    }

    function test_EmergencyWithdraw_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        collateralManager.emergencyWithdraw(Constants.ETH_TOKEN, 1 ether);
    }

    function test_EmergencyWithdraw_RevertInsufficientBalance() public {
        vm.expectRevert(ICollateralManager.InsufficientCollateral.selector);
        collateralManager.emergencyWithdraw(Constants.ETH_TOKEN, 1 ether);
    }

    // ============ REENTRANCY PROTECTION TESTS ============

    function test_ReentrancyProtection_Deposit() public {
        // Fund the stableGuard for the attack
        vm.deal(address(stableGuard), 2 ether);

        // First, make a legitimate deposit to user1's account
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: 1 ether}(user1, Constants.ETH_TOKEN, 1 ether);

        // Now try to attack via withdraw (which should fail due to reentrancy guard)
        vm.expectRevert();
        stableGuard.startReentrancyAttack(user1, Constants.ETH_TOKEN, 1 ether);
    }

    // ============ RECEIVE FUNCTION TESTS ============

    function test_Receive_Success() public {
        vm.prank(address(stableGuard));
        (bool success,) = address(collateralManager).call{value: 1 ether}("");
        assertTrue(success);
    }

    function test_Receive_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(ICollateralManager.Unauthorized.selector);
        (bool success,) = address(collateralManager).call{value: 1 ether}("");
        assertFalse(success);
    }

    // ============ INTEGRATION TESTS ============

    function test_MultipleDepositsAndWithdrawals() public {
        // Multiple deposits
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: 1 ether}(user1, Constants.ETH_TOKEN, 1 ether);

        vm.prank(address(stableGuard));
        collateralManager.deposit(user1, address(usdc), 1000e6);

        vm.prank(address(stableGuard));
        collateralManager.deposit(user1, address(wbtc), 1e8);

        // Check user tokens
        address[] memory userTokens = collateralManager.getUserTokens(user1);
        assertEq(userTokens.length, 3);

        // Check total value: 1 ETH ($2000) + 1000 USDC (6 dec, $1000) + 1 WBTC (8 dec, $30000)
        uint256 totalValue = collateralManager.getTotalCollateralValue(user1);
        uint256 expectedValue = (1 ether * ETH_PRICE) / 1e18 + (1000e6 * USDC_PRICE) / 1e6 + (1e8 * WBTC_PRICE) / 1e8;
        assertEq(totalValue, expectedValue);
        assertEq(totalValue, 33000e18);

        // Partial withdrawal
        vm.prank(address(stableGuard));
        collateralManager.withdraw(user1, address(usdc), 500e6, address(stableGuard));

        assertEq(collateralManager.getUserCollateral(user1, address(usdc)), 500e6);

        // Complete withdrawal of one token
        vm.prank(address(stableGuard));
        collateralManager.withdraw(user1, address(usdc), 500e6, address(stableGuard));

        userTokens = collateralManager.getUserTokens(user1);
        assertEq(userTokens.length, 2);
        assertEq(collateralManager.getUserCollateral(user1, address(usdc)), 0);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_DepositWithdraw(uint256 amount) public {
        // Bound the amount to reasonable values
        amount = bound(amount, 1, 1000 ether);

        // Fund the stableGuard
        vm.deal(address(stableGuard), amount);

        // Deposit
        vm.prank(address(stableGuard));
        collateralManager.deposit{value: amount}(user1, Constants.ETH_TOKEN, amount);

        assertEq(collateralManager.getUserCollateral(user1, Constants.ETH_TOKEN), amount);

        // Withdraw
        vm.prank(address(stableGuard));
        collateralManager.withdraw(user1, Constants.ETH_TOKEN, amount, address(stableGuard));

        assertEq(collateralManager.getUserCollateral(user1, Constants.ETH_TOKEN), 0);
    }

    function testFuzz_CanLiquidate(uint256 debtValue, uint256 collateralValue) public {
        // Bound values to prevent overflow
        debtValue = bound(debtValue, 1, 1000000e18);
        collateralValue = bound(collateralValue, 1, 1000000e18);

        // Mock the total collateral value
        uint256 ethAmount = (collateralValue * 1e18) / ETH_PRICE;
        ethAmount = bound(ethAmount, 1, 1000 ether);

        vm.deal(address(stableGuard), ethAmount);

        vm.prank(address(stableGuard));
        collateralManager.deposit{value: ethAmount}(user1, Constants.ETH_TOKEN, ethAmount);

        bool canLiquidate = collateralManager.canLiquidate(user1, debtValue, 12000); // 120%

        uint256 actualCollateralValue = collateralManager.getTotalCollateralValue(user1);
        uint256 requiredCollateral = (debtValue * 12000) / 10000;

        if (actualCollateralValue < requiredCollateral) {
            assertTrue(canLiquidate);
        } else {
            assertFalse(canLiquidate);
        }
    }

    // Allow the test contract to receive ETH
    receive() external payable {}
}
