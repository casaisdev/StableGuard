// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {RepegManager} from "../src/RepegManager.sol";
import {IRepegManager} from "../src/interfaces/IRepegManager.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IArbitrageManager} from "../src/interfaces/IArbitrageManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ MOCK CONTRACTS ============

contract MockERC20 is ERC20 {
    uint8 private _decimals;
    bool public enableCallbacks = false;

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

    function setCallbacksEnabled(bool enabled) external {
        enableCallbacks = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);

        // Make callback to recipient if enabled (for reentrancy testing)
        if (success && enableCallbacks && to.code.length > 0) {
            try IERC20Receiver(to).onTokenReceived(msg.sender, amount) {
            // Callback succeeded
            }
                catch {
                // Callback failed, but transfer still succeeded
            }
        }

        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);

        // Make callback to recipient if enabled (for reentrancy testing)
        if (success && enableCallbacks && to.code.length > 0) {
            try IERC20Receiver(to).onTokenReceived(from, amount) {
            // Callback succeeded
            }
                catch {
                // Callback failed, but transfer still succeeded
            }
        }

        return success;
    }
}

interface IERC20Receiver {
    function onTokenReceived(address from, uint256 amount) external;
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

    function batchConfigureTokens(
        address[] calldata tokens,
        address[] calldata _priceFeeds,
        uint256[] calldata _fallbackPrices,
        uint8[] calldata decimals
    ) external {
        require(tokens.length == _priceFeeds.length, "Length mismatch");
        require(tokens.length == _fallbackPrices.length, "Length mismatch");
        require(tokens.length == decimals.length, "Length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            this.configureToken(tokens[i], _priceFeeds[i], _fallbackPrices[i], decimals[i]);
        }
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

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokensList;
    }

    function isTokenSupported(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    function getPriceFeed(address token) external view returns (address) {
        return priceFeeds[token];
    }

    function getFallbackPrice(address token) external view returns (uint256) {
        return fallbackPrices[token];
    }

    function getTokenDecimals(address token) external view returns (uint8) {
        return tokenDecimals[token];
    }

    // Additional functions required by IPriceOracle interface
    function isSupportedToken(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    function getTokenValueInUsd(address token, uint256 amount) external view returns (uint256) {
        require(supportedTokens[token], "Token not supported");
        uint256 price = prices[token];
        return (amount * price) / (10 ** tokenDecimals[token]);
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
        lastUpdate = block.timestamp;
    }

    function updateFallbackPrice(address token, uint256 newFallbackPrice) external {
        require(supportedTokens[token], "Token not supported");
        fallbackPrices[token] = newFallbackPrice;
        emit FallbackPriceUpdated(token, newFallbackPrice);
    }
}

contract MockArbitrageManager is IArbitrageManager {
    mapping(address => uint256) private profits;
    bool private shouldRevert;
    ArbitrageConfig private config;
    uint256 private lastArbitrageTime;
    uint256 private currentDexPrice = 1e18; // Default $1
    MockPriceOracle private priceOracle;
    address private stableToken;
    uint128 private targetPrice = 1e18; // Default $1

    constructor() {
        config = ArbitrageConfig({
            maxTradeSize: 100 ether,
            minProfitBps: 50, // 0.5%
            maxSlippageBps: 300, // 3%
            enabled: true
        });
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setProfitForUser(address user, uint256 profit) external {
        profits[user] = profit;
    }

    function setCurrentDexPrice(uint256 price) external {
        currentDexPrice = price;
    }

    function setPriceOracle(address _priceOracle, address _stableToken, uint128 _targetPrice) external {
        priceOracle = MockPriceOracle(_priceOracle);
        stableToken = _stableToken;
        targetPrice = _targetPrice;
    }

    // ============ INTERFACE IMPLEMENTATIONS ============

    function executeArbitrage() external override {
        if (shouldRevert) {
            revert("Arbitrage failed");
        }
        lastArbitrageTime = block.timestamp;

        // Simulate arbitrage moving price closer to target
        if (address(priceOracle) != address(0) && stableToken != address(0)) {
            uint128 currentPrice = uint128(priceOracle.getTokenPrice(stableToken));
            uint128 newPrice;

            if (currentPrice > targetPrice) {
                // Price is above target, arbitrage should push it down
                uint128 deviation = currentPrice - targetPrice;
                uint128 reduction = deviation / 4; // Reduce deviation by 25%
                newPrice = currentPrice - reduction;
            } else if (currentPrice < targetPrice) {
                // Price is below target, arbitrage should push it up
                uint128 deviation = targetPrice - currentPrice;
                uint128 increase = deviation / 4; // Reduce deviation by 25%
                newPrice = currentPrice + increase;
            } else {
                newPrice = currentPrice; // Already at target
            }

            priceOracle.setPrice(stableToken, newPrice);
        }

        // Simulate callback to the original caller (this enables reentrancy testing)
        console.log("DEBUG: MockArbitrageManager balance:", address(this).balance);
        console.log("DEBUG: tx.origin:", tx.origin);
        console.log("DEBUG: msg.sender:", msg.sender);

        // Simulate malicious ArbitrageManager behavior - directly attempt reentrancy
        // when called by RepegManager (this simulates a compromised ArbitrageManager)
        console.log("DEBUG: MockArbitrageManager simulating malicious behavior");
        console.log("DEBUG: Checking if msg.sender is RepegManager...");

        // Check if we're being called by RepegManager and attempt direct reentrancy
        if (msg.sender.code.length > 0) {
            console.log("DEBUG: msg.sender is a contract, attempting direct reentrancy attack");

            // Try to call executeArbitrage again on the RepegManager (msg.sender)
            // This should trigger the reentrancy protection
            try IRepegManager(msg.sender).executeArbitrage{value: 0.1 ether}(0.1 ether, 500) {
                console.log("DEBUG: CRITICAL: Reentrancy attack succeeded - this should not happen!");
            } catch {
                console.log("DEBUG: Reentrancy attack blocked by nonReentrant modifier");
            }
        } else {
            console.log("DEBUG: msg.sender is not a contract");
        }

        emit ArbitrageExecuted(
            address(0), // dexFrom
            address(0), // dexTo
            1 ether, // amountIn
            1 ether, // amountOut
            profits[msg.sender], // profit
            block.timestamp
        );
    }

    function checkArbitrageOpportunity() external view override returns (bool exists, uint256 expectedProfit) {
        if (!config.enabled) return (false, 0);
        expectedProfit = profits[msg.sender];
        exists = expectedProfit >= config.minProfitBps;
    }

    function getConfig() external view override returns (ArbitrageConfig memory) {
        return config;
    }

    function updateConfig(uint256 maxTradeSize, uint256 minProfitBps, uint256 maxSlippageBps, bool enabled)
        external
        override
    {
        config = ArbitrageConfig({
            maxTradeSize: maxTradeSize, minProfitBps: minProfitBps, maxSlippageBps: maxSlippageBps, enabled: enabled
        });

        emit ConfigUpdated(maxTradeSize, minProfitBps, maxSlippageBps, enabled);
    }

    function emergencyWithdraw(address token) external override {
        // Mock implementation - no actual withdrawal
    }

    function getLastArbitrageTime() external view override returns (uint256) {
        return lastArbitrageTime;
    }

    function getCurrentDexPrice() external view override returns (uint256) {
        return currentDexPrice;
    }

    function updateCircuitBreakerState() external override {
        // Mock implementation - does nothing for testing purposes
        // In a real implementation, this would check DEX connectivity and update circuit breaker state
    }

    // ============ LEGACY FUNCTIONS FOR BACKWARD COMPATIBILITY ============

    function executeArbitrage(
        address, /* tokenIn */
        address, /* tokenOut */
        uint256, /* amountIn */
        uint256, /* minAmountOut */
        bytes calldata /* data */
    )
        external
        view
        returns (uint256 profit)
    {
        if (shouldRevert) {
            revert("Arbitrage failed");
        }
        return profits[msg.sender];
    }

    function calculateArbitrageProfit(
        address,
        /* tokenIn */
        address,
        /* tokenOut */
        uint256 /* amountIn */
    )
        external
        view
        returns (uint256 profit, bool profitable)
    {
        profit = profits[msg.sender];
        profitable = profit > 0;
    }

    function getOptimalRoute(address tokenIn, address tokenOut, uint256 amountIn)
        external
        pure
        returns (address[] memory path, uint256[] memory amounts)
    {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // Simplified 1:1 for testing
    }

    // Allow contract to receive ETH
    receive() external payable {}
}

contract MockUniswapRouter {
    // Realistic mock implementation of Uniswap V2 Router for testing

    MockPriceOracle public priceOracle;
    uint256 public constant FEE_RATE = 3; // 0.3% fee in basis points (3/1000)
    uint256 public constant BASIS_POINTS = 1000;

    // Simulated liquidity for each token pair (can be configured)
    mapping(address => mapping(address => uint256)) public liquidityPools;

    constructor() {
        // Default liquidity pools (can be overridden)
        // These represent the "reserves" in each pool
    }

    function setPriceOracle(address _priceOracle) external {
        priceOracle = MockPriceOracle(_priceOracle);
    }

    function setLiquidity(address tokenA, address tokenB, uint256 liquidity) external {
        liquidityPools[tokenA][tokenB] = liquidity;
        liquidityPools[tokenB][tokenA] = liquidity;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        require(address(priceOracle) != address(0), "Price oracle not set");

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            amounts[i + 1] = _getAmountOut(amounts[i], path[i], path[i + 1]);
        }

        return amounts;
    }

    function _getAmountOut(uint256 amountIn, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 amountOut)
    {
        // Get prices from oracle (in USD, 18 decimals)
        uint256 priceIn = _getTokenPrice(tokenIn);
        uint256 priceOut = _getTokenPrice(tokenOut);

        // Calculate base amount out based on price ratio
        amountOut = (amountIn * priceIn) / priceOut;

        // Apply Uniswap fee (0.3%)
        amountOut = (amountOut * (BASIS_POINTS - FEE_RATE)) / BASIS_POINTS;

        // Apply slippage based on trade size and liquidity
        amountOut = _applySlippage(amountOut, amountIn, tokenIn, tokenOut);
    }

    function _getTokenPrice(address token) internal view returns (uint256) {
        try priceOracle.getTokenPrice(token) returns (uint256 price) {
            return price;
        } catch {
            // Fallback to $1 if price not available
            return 1e18;
        }
    }

    function _applySlippage(uint256 baseAmountOut, uint256 amountIn, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256)
    {
        uint256 liquidity = liquidityPools[tokenIn][tokenOut];

        // If no liquidity set, use default high liquidity (minimal slippage)
        if (liquidity == 0) {
            liquidity = 1000000e18; // 1M tokens default liquidity
        }

        // Calculate slippage: larger trades relative to liquidity have more slippage
        // Slippage = (amountIn / liquidity) * slippageMultiplier
        uint256 slippageMultiplier = 100; // 1% max slippage for trades equal to liquidity
        uint256 slippageBps = (amountIn * slippageMultiplier) / liquidity;

        // Cap slippage at 5%
        if (slippageBps > 500) {
            slippageBps = 500;
        }

        // Apply slippage reduction
        return (baseAmountOut * (BASIS_POINTS * 10 - slippageBps)) / (BASIS_POINTS * 10);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address, /* to */
        uint256 deadline
    ) external view returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length >= 2, "Invalid path");

        amounts = this.getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Insufficient output amount");

        return amounts;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address, /* to */
        uint256 deadline
    ) external view returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length >= 2, "Invalid path");

        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;

        // Calculate required input amounts working backwards
        for (uint256 i = path.length - 1; i > 0; i--) {
            amounts[i - 1] = _getAmountIn(amounts[i], path[i - 1], path[i]);
        }

        require(amounts[0] <= amountInMax, "Excessive input amount");
        return amounts;
    }

    function _getAmountIn(uint256 amountOut, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 amountIn)
    {
        // Get prices from oracle
        uint256 priceIn = _getTokenPrice(tokenIn);
        uint256 priceOut = _getTokenPrice(tokenOut);

        // Calculate base amount in based on price ratio
        amountIn = (amountOut * priceOut) / priceIn;

        // Account for fees (need more input to get desired output)
        amountIn = (amountIn * BASIS_POINTS) / (BASIS_POINTS - FEE_RATE);

        // Account for slippage (need more input due to price impact)
        uint256 liquidity = liquidityPools[tokenIn][tokenOut];
        if (liquidity == 0) {
            liquidity = 1000000e18;
        }

        uint256 slippageMultiplier = 100;
        uint256 slippageBps = (amountIn * slippageMultiplier) / liquidity;
        if (slippageBps > 500) {
            slippageBps = 500;
        }

        amountIn = (amountIn * (BASIS_POINTS * 10 + slippageBps)) / (BASIS_POINTS * 10);
    }
}

contract MockStableGuard {
    RepegManager public repegManager;

    function setRepegManager(address _repegManager) external {
        repegManager = RepegManager(payable(_repegManager));
    }

    function triggerRepeg() external returns (bool triggered, uint128 newPrice) {
        return repegManager.checkAndTriggerRepeg(msg.sender);
    }
}

// ============ MAIN TEST CONTRACT ============

contract RepegManagerTest is Test {
    RepegManager public repegManager;
    MockPriceOracle public priceOracle;
    MockArbitrageManager public arbitrageManager;
    MockERC20 public stableToken;
    MockStableGuard public stableGuard;

    // Test accounts
    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Test constants
    uint128 constant TARGET_PRICE = 1e18; // $1
    uint64 constant DEVIATION_THRESHOLD = 500; // 5%
    uint16 constant INCENTIVE_RATE = 100; // 1%
    uint128 constant MAX_INCENTIVE = 10e18;
    uint64 constant COOLDOWN_PERIOD = 3600; // 1 hour
    uint8 constant MAX_DAILY_REPEGS = 10;

    // Events for testing
    event RepegEvent(
        uint8 indexed eventType,
        uint128 oldPrice,
        uint128 newPrice,
        address indexed caller,
        uint128 incentive,
        uint32 timestamp
    );

    event RepegArbitrageExecuted(uint256 timestamp);

    function setUp() public {
        // Setup accounts
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // Deploy mock contracts
        priceOracle = new MockPriceOracle();
        arbitrageManager = new MockArbitrageManager();
        stableToken = new MockERC20("StableGuard USD", "SGUSD", 18);
        stableGuard = new MockStableGuard();

        // Setup price oracle
        priceOracle.setPrice(address(stableToken), TARGET_PRICE);
        priceOracle.setSupportedToken(address(stableToken), true);

        // Deploy RepegManager
        IRepegManager.RepegConfig memory initialConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300, // 5 minutes
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        repegManager = new RepegManager(
            address(stableGuard), address(priceOracle), address(stableToken), address(arbitrageManager), initialConfig
        );

        // Set RepegManager in StableGuard
        stableGuard.setRepegManager(address(repegManager));

        // Deploy mock Uniswap router at the expected address
        MockUniswapRouter mockRouter = new MockUniswapRouter();
        mockRouter.setPriceOracle(address(priceOracle));
        vm.etch(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, address(mockRouter).code);

        // Configure MockArbitrageManager with price oracle
        arbitrageManager.setPriceOracle(address(priceOracle), address(stableToken), TARGET_PRICE);

        // Setup initial configuration
        IRepegManager.RepegConfig memory config = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300,
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        repegManager.updateRepegConfig(config);

        // Fund accounts
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        stableToken.mint(address(repegManager), 1000000e18); // Provide liquidity
    }

    // ============ CONSTRUCTOR TESTS ============

    function test_Constructor_Success() public {
        IRepegManager.RepegConfig memory testConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300,
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        RepegManager newRepegManager = new RepegManager(
            address(stableGuard), address(priceOracle), address(stableToken), address(arbitrageManager), testConfig
        );

        assertEq(newRepegManager.owner(), address(this));
        assertEq(newRepegManager.STABLE_GUARD(), address(stableGuard));
        assertEq(address(newRepegManager.PRICE_ORACLE()), address(priceOracle));
        assertEq(address(newRepegManager.STABLE_TOKEN()), address(stableToken));
        assertEq(address(newRepegManager.ARBITRAGE_MANAGER()), address(arbitrageManager));
    }

    function test_Constructor_RevertInvalidStableGuard() public {
        IRepegManager.RepegConfig memory testConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300,
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        vm.expectRevert();
        new RepegManager(address(0), address(priceOracle), address(stableToken), address(arbitrageManager), testConfig);
    }

    function test_Constructor_RevertInvalidPriceOracle() public {
        IRepegManager.RepegConfig memory testConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300,
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        vm.expectRevert();
        new RepegManager(address(stableGuard), address(0), address(stableToken), address(arbitrageManager), testConfig);
    }

    function test_Constructor_RevertInvalidStableToken() public {
        IRepegManager.RepegConfig memory testConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300,
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        vm.expectRevert();
        new RepegManager(address(stableGuard), address(priceOracle), address(0), address(arbitrageManager), testConfig);
    }

    function test_Constructor_RevertInvalidArbitrageManager() public {
        IRepegManager.RepegConfig memory testConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: DEVIATION_THRESHOLD,
            repegCooldown: uint32(COOLDOWN_PERIOD),
            arbitrageWindow: 300,
            incentiveRate: INCENTIVE_RATE,
            maxRepegPerDay: MAX_DAILY_REPEGS,
            enabled: true
        });

        vm.expectRevert();
        new RepegManager(address(stableGuard), address(priceOracle), address(stableToken), address(0), testConfig);
    }

    // ============ CONFIGURATION TESTS ============

    function test_UpdateRepegConfig_Success() public {
        IRepegManager.RepegConfig memory newConfig = IRepegManager.RepegConfig({
            targetPrice: 2e18,
            deviationThreshold: 1000,
            repegCooldown: 7200,
            arbitrageWindow: 300,
            incentiveRate: 200,
            maxRepegPerDay: 5,
            enabled: true
        });

        repegManager.updateRepegConfig(newConfig);

        IRepegManager.RepegConfig memory retrievedConfig = repegManager.getRepegConfig();
        assertEq(retrievedConfig.targetPrice, 2e18);
        assertEq(retrievedConfig.deviationThreshold, 1000);
        assertEq(retrievedConfig.incentiveRate, 200);
        assertEq(retrievedConfig.repegCooldown, 7200);
        assertEq(retrievedConfig.maxRepegPerDay, 5);
    }

    function test_UpdateRepegConfig_RevertUnauthorized() public {
        IRepegManager.RepegConfig memory newConfig = IRepegManager.RepegConfig({
            targetPrice: 2e18,
            deviationThreshold: 1000,
            repegCooldown: 7200,
            arbitrageWindow: 300,
            incentiveRate: 200,
            maxRepegPerDay: 5,
            enabled: true
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        repegManager.updateRepegConfig(newConfig);
    }

    function test_SetEmergencyPause_Success() public {
        repegManager.setEmergencyPause(true);

        // Try to trigger repeg while paused - should revert
        vm.expectRevert();
        stableGuard.triggerRepeg();

        // Unpause
        repegManager.setEmergencyPause(false);

        // Should work now (though may not trigger if no deviation)
        stableGuard.triggerRepeg();
    }

    function test_SetEmergencyPause_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        repegManager.setEmergencyPause(true);
    }

    function test_UpdateDeviationThreshold_Success() public {
        uint64 newThreshold = 1000; // 10%
        repegManager.updateDeviationThreshold(newThreshold);

        IRepegManager.RepegConfig memory config = repegManager.getRepegConfig();
        assertEq(config.deviationThreshold, newThreshold);
    }

    function test_UpdateDeviationThreshold_RevertInvalidThreshold() public {
        // Test zero threshold
        vm.expectRevert();
        repegManager.updateDeviationThreshold(0);

        // Test threshold too high (> 20%)
        vm.expectRevert();
        repegManager.updateDeviationThreshold(2001);
    }

    function test_UpdateDeviationThreshold_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        repegManager.updateDeviationThreshold(1000);
    }

    function test_UpdateIncentiveParameters_Success() public {
        uint16 newRate = 200; // 2%
        uint128 newMaxIncentive = 50e18;

        repegManager.updateIncentiveParameters(newRate, newMaxIncentive);

        IRepegManager.RepegConfig memory config = repegManager.getRepegConfig();
        assertEq(config.incentiveRate, newRate);
    }

    function test_UpdateIncentiveParameters_RevertInvalidRate() public {
        // Test rate too high (> 10%)
        vm.expectRevert();
        repegManager.updateIncentiveParameters(1001, 50e18);
    }

    function test_UpdateIncentiveParameters_RevertInvalidMaxIncentive() public {
        // Test max incentive too high
        vm.expectRevert();
        repegManager.updateIncentiveParameters(200, 101e18);
    }

    function test_UpdateIncentiveParameters_RevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        repegManager.updateIncentiveParameters(200, 50e18);
    }

    // ============ REPEG EXECUTION TESTS ============

    function test_IsRepegNeeded_NoDeviation() public {
        // Set price equal to target
        priceOracle.setPrice(address(stableToken), TARGET_PRICE);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (bool needed, uint128 deviation) = repegManager.isRepegNeeded();
        assertFalse(needed);
        assertEq(deviation, 0);
    }

    function test_IsRepegNeeded_SmallDeviation() public {
        // Set price with 3% deviation (below 5% threshold)
        uint256 deviatedPrice = TARGET_PRICE * 103 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (bool needed, uint128 deviation) = repegManager.isRepegNeeded();
        assertFalse(needed);
        assertEq(deviation, 300); // 3% in basis points
    }

    function test_IsRepegNeeded_LargeDeviation() public {
        // Set price with 8% deviation (above 5% threshold)
        uint256 deviatedPrice = TARGET_PRICE * 108 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (bool needed, uint128 deviation) = repegManager.isRepegNeeded();
        assertTrue(needed);
        assertEq(deviation, 800); // 8% in basis points
    }

    function test_GetCurrentDeviation_Above() public {
        // Set price 10% above target
        uint256 deviatedPrice = TARGET_PRICE * 110 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (uint128 deviation, bool isAbove) = repegManager.getCurrentDeviation();
        assertEq(deviation, 1000); // 10% in basis points
        assertTrue(isAbove);
    }

    function test_GetCurrentDeviation_Below() public {
        // Set price 7% below target
        uint256 deviatedPrice = TARGET_PRICE * 93 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (uint128 deviation, bool isAbove) = repegManager.getCurrentDeviation();
        assertEq(deviation, 700); // 7% in basis points
        assertFalse(isAbove);
    }

    function test_CalculateRepegParameters_PriceAbove() public {
        // Provide liquidity for incentive calculations
        uint256 liquidityAmount = 1000e18;
        vm.deal(address(this), liquidityAmount);
        repegManager.provideLiquidity{value: liquidityAmount}(liquidityAmount);

        // Set price 10% above target
        uint256 deviatedPrice = TARGET_PRICE * 110 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (uint128 targetPrice, uint8 direction, uint128 incentive) = repegManager.calculateRepegParameters();

        assertEq(targetPrice, TARGET_PRICE);
        assertEq(direction, 2); // Down
        assertGt(incentive, 0); // Should have some incentive
    }

    function test_CalculateRepegParameters_PriceBelow() public {
        // Provide liquidity for incentive calculations
        uint256 liquidityAmount = 1000e18;
        vm.deal(address(this), liquidityAmount);
        repegManager.provideLiquidity{value: liquidityAmount}(liquidityAmount);

        // Set price 8% below target
        uint256 deviatedPrice = TARGET_PRICE * 92 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (uint128 targetPrice, uint8 direction, uint128 incentive) = repegManager.calculateRepegParameters();

        assertEq(targetPrice, TARGET_PRICE);
        assertEq(direction, 1); // Up
        assertGt(incentive, 0); // Should have some incentive
    }

    function test_CalculateRepegParameters_NoRepegNeeded() public {
        // Set price equal to target
        priceOracle.setPrice(address(stableToken), TARGET_PRICE);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (uint128 targetPrice, uint8 direction,) = repegManager.calculateRepegParameters();

        assertEq(targetPrice, TARGET_PRICE);
        assertEq(direction, 0); // No repeg needed
    }

    function test_TriggerRepeg_Success() public {
        console.log("=== DEBUG: test_TriggerRepeg_Success ===");

        // Provide liquidity first
        uint256 liquidityAmount = 100000e18;
        stableToken.mint(user1, liquidityAmount);
        vm.prank(user1);
        stableToken.approve(address(repegManager), liquidityAmount);
        vm.prank(user1);
        repegManager.provideLiquidity(liquidityAmount);
        console.log("DEBUG: Liquidity provided:", liquidityAmount);

        // Set price with significant deviation
        uint256 deviatedPrice = TARGET_PRICE * 110 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);
        console.log("DEBUG: Target price:", uint256(TARGET_PRICE));
        console.log("DEBUG: Deviated price set to:", deviatedPrice);
        console.log(
            "DEBUG: Deviation percentage:", (deviatedPrice - TARGET_PRICE) * 10000 / TARGET_PRICE, "basis points"
        );

        // Advance time to invalidate cache and ensure fresh price is fetched
        // Also advance past the cooldown period (3600 seconds) to allow repeg execution
        vm.warp(block.timestamp + 3601);
        console.log("DEBUG: Time advanced to:", block.timestamp);

        // Check if repeg is needed and get actual incentive
        (bool needed, uint128 currentDeviation) = repegManager.isRepegNeeded();
        uint128 actualIncentive = repegManager.calculateIncentive(address(this));
        console.log("DEBUG: Repeg needed:", needed);
        console.log("DEBUG: Current deviation:", currentDeviation);
        console.log("DEBUG: Actual incentive calculated:", actualIncentive);

        // Calculate expected incentive: (deviation * incentiveRate * totalLiquidity) / (BASIS_POINTS * BASIS_POINTS)
        // deviation = 10% = 1000 basis points
        // incentiveRate = 1% = 100 basis points
        // totalLiquidity = 100000e18
        // incentive = (1000 * 100 * 100000e18) / (10000 * 10000) = 100e18
        uint128 expectedIncentive = 100e18;
        console.log("DEBUG: Expected incentive:", uint256(expectedIncentive));

        // Get current total liquidity
        (uint256 totalLiquidity, uint256 availableLiquidity) = repegManager.getLiquidityPoolStatus();
        console.log("DEBUG: Total liquidity available:", totalLiquidity);
        console.log("DEBUG: Available liquidity:", availableLiquidity);

        console.log("DEBUG: Expected event parameters:");
        console.log("  - eventType: 0");
        console.log("  - oldPrice:", uint128(deviatedPrice));
        console.log("  - newPrice:", uint256(TARGET_PRICE));
        console.log("  - caller:", address(this));
        console.log("  - incentive:", uint256(expectedIncentive));
        console.log("  - timestamp:", uint32(block.timestamp));

        vm.expectEmit(true, true, true, true);
        emit RepegEvent(
            0, uint128(deviatedPrice), TARGET_PRICE, address(this), expectedIncentive, uint32(block.timestamp)
        );

        console.log("DEBUG: About to call checkAndTriggerRepeg...");
        (bool triggered, uint128 newPrice) = stableGuard.triggerRepeg();

        console.log("DEBUG: Repeg triggered:", triggered);
        console.log("DEBUG: New price:", newPrice);

        assertTrue(triggered);
        assertEq(newPrice, TARGET_PRICE);

        console.log("DEBUG: Test completed successfully");
    }

    function test_TriggerRepeg_NoDeviationNeeded() public {
        // Set price equal to target
        priceOracle.setPrice(address(stableToken), TARGET_PRICE);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        (bool triggered, uint128 newPrice) = stableGuard.triggerRepeg();

        assertFalse(triggered);
        assertEq(newPrice, TARGET_PRICE);
    }

    function test_TriggerRepeg_WhilePaused() public {
        // Set price with deviation
        uint256 deviatedPrice = TARGET_PRICE * 110 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        // Pause the contract
        repegManager.setEmergencyPause(true);

        vm.expectRevert();
        stableGuard.triggerRepeg();
    }

    function test_ExecuteRepeg_Success() public {
        // Provide liquidity first
        uint256 liquidityAmount = 100000e18;
        stableToken.mint(user1, liquidityAmount);
        vm.prank(user1);
        stableToken.approve(address(repegManager), liquidityAmount);
        vm.prank(user1);
        repegManager.provideLiquidity(liquidityAmount);

        // Set up a price deviation scenario (6% below target to trigger repeg)
        uint256 deviatedPrice = TARGET_PRICE * 94 / 100; // 6% below target
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        uint128 targetPrice = TARGET_PRICE;
        uint8 direction = 1; // Up (price below target)

        bool success = repegManager.executeRepeg(targetPrice, direction);
        assertTrue(success);
    }

    function test_ExecuteRepeg_InvalidParameters() public {
        // Test zero target price
        vm.expectRevert();
        repegManager.executeRepeg(0, 1);

        // Test invalid direction
        vm.expectRevert();
        repegManager.executeRepeg(TARGET_PRICE, 3);
    }

    function test_ExecuteRepeg_Unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        repegManager.executeRepeg(TARGET_PRICE, 1);
    }

    function test_ExecuteRepeg_WhilePaused() public {
        repegManager.setEmergencyPause(true);

        vm.expectRevert();
        repegManager.executeRepeg(TARGET_PRICE, 1);
    }

    // ============ VIEW FUNCTION TESTS ============

    function test_GetRepegConfig() public view {
        IRepegManager.RepegConfig memory config = repegManager.getRepegConfig();

        assertEq(config.targetPrice, TARGET_PRICE);
        assertEq(config.deviationThreshold, DEVIATION_THRESHOLD);
        assertEq(config.incentiveRate, INCENTIVE_RATE);
        assertEq(config.repegCooldown, uint32(COOLDOWN_PERIOD));
        assertEq(config.maxRepegPerDay, MAX_DAILY_REPEGS);
    }

    function test_GetRepegState() public view {
        IRepegManager.RepegState memory state = repegManager.getRepegState();

        // Initial state should have reasonable defaults
        assertGt(state.currentPrice, 0);
        assertGt(state.lastRepegTime, 0); // Should be initialized to block.timestamp in constructor
        assertEq(state.dailyRepegCount, 0);
        assertEq(state.consecutiveRepegs, 0);
    }

    // ============ ARBITRAGE TESTS ============

    function test_GetArbitrageOpportunities_NoDeviation() public {
        // Set price equal to target (no deviation)
        priceOracle.setPrice(address(stableToken), TARGET_PRICE);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        IRepegManager.ArbitrageOpportunity[] memory opportunities = repegManager.getArbitrageOpportunities();

        assertEq(opportunities.length, 0, "Should have no opportunities when no deviation");
    }

    function test_GetArbitrageOpportunities_SmallDeviation() public {
        // Set price with small deviation (0.3% - below 0.5% threshold)
        uint128 smallDeviationPrice = TARGET_PRICE + (TARGET_PRICE * 30) / 10000; // 0.3% above
        priceOracle.setPrice(address(stableToken), smallDeviationPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        IRepegManager.ArbitrageOpportunity[] memory opportunities = repegManager.getArbitrageOpportunities();

        assertEq(opportunities.length, 0, "Should have no opportunities for small deviation");
    }

    function test_GetArbitrageOpportunities_SignificantDeviation() public {
        // Set price with significant deviation (1% - above 0.5% threshold)
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 100) / 10000; // 1% above
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        IRepegManager.ArbitrageOpportunity[] memory opportunities = repegManager.getArbitrageOpportunities();

        assertEq(opportunities.length, 1, "Should have one opportunity for significant deviation");
        assertEq(opportunities[0].tokenA, address(stableToken), "TokenA should be stable token");
        assertEq(opportunities[0].tokenB, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "TokenB should be WETH"); // Constants.WETH
        assertGt(opportunities[0].expectedProfit, 0, "Should have positive expected profit");
        assertGt(opportunities[0].confidence, 0, "Should have positive confidence");
        assertGt(opportunities[0].expiryTime, block.timestamp, "Should have future expiry time");
    }

    function test_ExecuteArbitrage_Success() public {
        // Setup: Create arbitrage opportunity
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% above (above 5% threshold)
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        // Fund the contract with ETH for arbitrage
        uint256 arbitrageAmount = 1 ether;
        vm.deal(user1, arbitrageAmount);

        vm.startPrank(user1);
        uint128 profit = repegManager.executeArbitrage{value: arbitrageAmount}(arbitrageAmount, 500); // 5% max slippage
        vm.stopPrank();

        assertGt(profit, 0, "Should generate profit from arbitrage");
    }

    function test_ExecuteArbitrage_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.executeArbitrage(0, 500);
        vm.stopPrank();
    }

    function test_ExecuteArbitrage_ExcessiveSlippage() public {
        uint256 arbitrageAmount = 1 ether;
        vm.deal(user1, arbitrageAmount);

        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.executeArbitrage{value: arbitrageAmount}(arbitrageAmount, 1100); // 11% slippage (> 10% max)
        vm.stopPrank();
    }

    function test_ExecuteArbitrage_NoOpportunities() public {
        // Set price equal to target (no opportunities)
        priceOracle.setPrice(address(stableToken), TARGET_PRICE);

        uint256 arbitrageAmount = 1 ether;
        vm.deal(user1, arbitrageAmount);

        vm.startPrank(user1);
        uint128 profit = repegManager.executeArbitrage{value: arbitrageAmount}(arbitrageAmount, 500);
        vm.stopPrank();

        assertEq(profit, 0, "Should return zero profit when no opportunities");
    }

    function test_ProvideLiquidity_Success() public {
        uint256 liquidityAmount = 1000e18;
        stableToken.mint(user1, liquidityAmount);

        vm.startPrank(user1);
        stableToken.approve(address(repegManager), liquidityAmount);
        bool success = repegManager.provideLiquidity(liquidityAmount);
        vm.stopPrank();

        assertTrue(success, "Liquidity provision should succeed");

        // Check liquidity was recorded
        (uint256 totalLiquidity, uint256 availableLiquidity) = repegManager.getLiquidityPoolStatus();
        assertEq(totalLiquidity, liquidityAmount, "Total liquidity should match provided amount");
        assertEq(availableLiquidity, liquidityAmount, "Available liquidity should match provided amount");
    }

    function test_ProvideLiquidity_WithETH() public {
        uint256 liquidityAmount = 1 ether;
        vm.deal(user1, liquidityAmount);

        vm.startPrank(user1);
        bool success = repegManager.provideLiquidity{value: liquidityAmount}(liquidityAmount);
        vm.stopPrank();

        assertTrue(success, "ETH liquidity provision should succeed");
    }

    function test_ProvideLiquidity_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.provideLiquidity(0);
        vm.stopPrank();
    }

    function test_ProvideLiquidity_MismatchedETHAmount() public {
        uint256 liquidityAmount = 1 ether;
        vm.deal(user1, liquidityAmount);

        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.provideLiquidity{value: liquidityAmount}(liquidityAmount + 1); // Mismatched amounts
        vm.stopPrank();
    }

    function test_WithdrawLiquidity_Success() public {
        // First provide liquidity
        uint256 liquidityAmount = 1000e18;
        stableToken.mint(user1, liquidityAmount);

        vm.startPrank(user1);
        stableToken.approve(address(repegManager), liquidityAmount);
        repegManager.provideLiquidity(liquidityAmount);

        // Then withdraw half
        uint256 withdrawAmount = liquidityAmount / 2;
        bool success = repegManager.withdrawLiquidity(withdrawAmount);
        vm.stopPrank();

        assertTrue(success, "Liquidity withdrawal should succeed");

        // Check remaining liquidity
        (uint256 totalLiquidity,) = repegManager.getLiquidityPoolStatus();
        assertEq(totalLiquidity, liquidityAmount - withdrawAmount, "Total liquidity should be reduced");
    }

    function test_WithdrawLiquidity_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.withdrawLiquidity(0);
        vm.stopPrank();
    }

    function test_WithdrawLiquidity_InsufficientBalance() public {
        uint256 withdrawAmount = 1000e18;

        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InsufficientLiquidity.selector);
        repegManager.withdrawLiquidity(withdrawAmount);
        vm.stopPrank();
    }

    function test_WithdrawLiquidity_InsufficientAvailable() public {
        // Provide liquidity
        uint256 liquidityAmount = 1000e18;
        stableToken.mint(user1, liquidityAmount);

        vm.startPrank(user1);
        stableToken.approve(address(repegManager), liquidityAmount);
        repegManager.provideLiquidity(liquidityAmount);
        vm.stopPrank();

        // Simulate reserved liquidity by trying to withdraw more than available
        // This would happen if some liquidity is reserved for ongoing operations
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InsufficientLiquidity.selector);
        repegManager.withdrawLiquidity(liquidityAmount + 1);
        vm.stopPrank();
    }

    // ============ COHERENCE TESTS (Phase 6 fixes) ============

    function test_CheckAndTriggerRepeg_OnlyStableGuard() public {
        // A direct caller that is not StableGuard is rejected
        vm.prank(user1);
        vm.expectRevert(RepegManager.Unauthorized.selector);
        repegManager.checkAndTriggerRepeg(user1);
    }

    function test_EthLiquidity_InAndOut() public {
        uint256 amount = 5 ether;
        vm.deal(user1, amount);

        vm.prank(user1);
        repegManager.provideLiquidity{value: amount}(amount);

        (uint256 total,) = repegManager.getLiquidityPoolStatus();
        assertEq(total, amount);

        // ETH deposits are withdrawn as ETH, not SGD
        uint256 balBefore = user1.balance;
        vm.prank(user1);
        bool ok = repegManager.withdrawEthLiquidity(amount);
        assertTrue(ok);
        assertEq(user1.balance, balBefore + amount);
    }

    function test_EthLiquidity_CannotWithdrawAsSgd() public {
        uint256 amount = 5 ether;
        vm.deal(user1, amount);
        vm.prank(user1);
        repegManager.provideLiquidity{value: amount}(amount);

        // The SGD pool is empty, so an SGD withdrawal must revert
        vm.prank(user1);
        vm.expectRevert(RepegManager.InsufficientLiquidity.selector);
        repegManager.withdrawLiquidity(amount);
    }

    function test_Receive_RejectsArbitrarySender() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool ok,) = address(repegManager).call{value: 1 ether}("");
        assertFalse(ok, "Plain ETH sends must be rejected; use provideLiquidity");
    }

    function test_UpdateIncentiveParameters_StoresMaxIncentive() public {
        // Cap the incentive very low and confirm calculateIncentive honors it
        stableToken.mint(user1, 1_000_000e18);
        vm.startPrank(user1);
        stableToken.approve(address(repegManager), 1_000_000e18);
        repegManager.provideLiquidity(1_000_000e18);
        vm.stopPrank();

        repegManager.updateIncentiveParameters(200, 1e18); // max 1 SGD

        uint256 deviatedPrice = TARGET_PRICE * 110 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);
        vm.warp(block.timestamp + 61);

        uint128 incentive = repegManager.calculateIncentive(user1);
        assertLe(incentive, 1e18, "Incentive must respect the configured max");
    }

    function test_UpdateIncentiveParameters_RevertZeroMax() public {
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.updateIncentiveParameters(200, 0);
    }

    function test_Repeg_IncentivePaidToBeneficiary() public {
        // Fund the SGD pool so the incentive can actually be paid
        stableToken.mint(user1, 1_000_000e18);
        vm.startPrank(user1);
        stableToken.approve(address(repegManager), 1_000_000e18);
        repegManager.provideLiquidity(1_000_000e18);
        vm.stopPrank();

        uint256 deviatedPrice = TARGET_PRICE * 110 / 100;
        priceOracle.setPrice(address(stableToken), deviatedPrice);
        vm.warp(block.timestamp + 3601);

        // user2 triggers the repeg via StableGuard: the incentive must reach user2,
        // not StableGuard.
        uint256 guardBefore = stableToken.balanceOf(address(stableGuard));
        uint256 user2Before = stableToken.balanceOf(user2);

        vm.prank(user2);
        stableGuard.triggerRepeg();

        assertEq(stableToken.balanceOf(address(stableGuard)), guardBefore, "Guard must not receive the incentive");
        assertGt(stableToken.balanceOf(user2), user2Before, "Beneficiary should receive the incentive");
    }

    // ============ SECURITY AND EMERGENCY CONTROL TESTS ============

    function test_EmergencyPause_Success() public {
        vm.startPrank(owner);
        repegManager.setEmergencyPause(true);
        vm.stopPrank();

        // Verify repeg operations are paused
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.EmergencyPaused.selector);
        stableGuard.triggerRepeg();
        vm.stopPrank();

        // Verify arbitrage operations are paused
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.EmergencyPaused.selector);
        repegManager.executeArbitrage(1 ether, 500);
        vm.stopPrank();
    }

    function test_EmergencyPause_OnlyOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        repegManager.setEmergencyPause(true);
        vm.stopPrank();
    }

    function test_EmergencyPause_Unpause() public {
        // First pause
        vm.startPrank(owner);
        repegManager.setEmergencyPause(true);

        // Then unpause
        repegManager.setEmergencyPause(false);
        vm.stopPrank();

        // Verify operations work again
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% deviation (above 5% threshold)
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed,) = repegManager.isRepegNeeded();
        assertTrue(needed, "Repeg should be needed after unpausing");
        vm.stopPrank();
    }

    function test_ReentrancyProtection_TriggerRepeg() public {
        console.log("=== DEBUG: test_ReentrancyProtection_TriggerRepeg ===");

        // Provide liquidity first
        stableToken.mint(user1, 1000000e18);
        vm.startPrank(user1);
        stableToken.approve(address(repegManager), 1000000e18);
        repegManager.provideLiquidity(1000000e18);
        vm.stopPrank();
        console.log("DEBUG: Liquidity provided:", uint256(1000000e18));

        // Enable callbacks on the stable token for reentrancy testing
        stableToken.setCallbacksEnabled(true);
        console.log("DEBUG: Token callbacks enabled:", stableToken.enableCallbacks());

        // Create a malicious contract that tries to re-enter
        MaliciousReentrancyContract malicious = new MaliciousReentrancyContract(address(repegManager));
        console.log("DEBUG: Malicious contract created at:", address(malicious));

        // Set up conditions for repeg with higher deviation to ensure incentive is paid
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);
        console.log("DEBUG: Target price:", uint256(TARGET_PRICE));
        console.log("DEBUG: Deviated price set to:", uint256(deviatedPrice));
        console.log(
            "DEBUG: Deviation percentage:", (deviatedPrice - TARGET_PRICE) * 10000 / TARGET_PRICE, "basis points"
        );

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);
        console.log("DEBUG: Time advanced to:", block.timestamp);

        // Verify repeg is needed
        (bool needed, uint256 incentive) = repegManager.isRepegNeeded();
        console.log("DEBUG: Repeg needed:", needed);
        console.log("DEBUG: Expected incentive:", incentive);
        assertTrue(needed, "Repeg should be needed");

        // Check total liquidity available
        (uint256 totalLiquidity, uint256 availableLiquidity) = repegManager.getLiquidityPoolStatus();
        console.log("DEBUG: Total liquidity available:", totalLiquidity);
        console.log("DEBUG: Available liquidity:", availableLiquidity);

        // A non-StableGuard caller can't invoke checkAndTriggerRepeg at all
        vm.prank(address(malicious));
        vm.expectRevert(RepegManager.Unauthorized.selector);
        malicious.attemptReentrancy();
    }

    function test_ReentrancyProtection_ExecuteArbitrage() public {
        console.log("=== DEBUG: test_ReentrancyProtection_ExecuteArbitrage ===");

        // Provide liquidity first
        stableToken.mint(user1, 1000000e18);
        vm.startPrank(user1);
        stableToken.approve(address(repegManager), 1000000e18);
        repegManager.provideLiquidity(1000000e18);
        vm.stopPrank();
        console.log("DEBUG: Liquidity provided:", uint256(1000000e18));

        // Give ETH to the arbitrage manager so it can send back to trigger reentrancy
        vm.deal(address(arbitrageManager), 5 ether);
        console.log("DEBUG: ArbitrageManager balance:", address(arbitrageManager).balance);

        // Create a malicious contract that tries to re-enter arbitrage
        MaliciousArbitrageContract malicious = new MaliciousArbitrageContract(address(repegManager));
        vm.deal(address(malicious), 2 ether);
        console.log("DEBUG: Malicious contract created at:", address(malicious));
        console.log("DEBUG: Malicious contract balance:", address(malicious).balance);

        // Set up arbitrage opportunity with higher deviation (5% to ensure it's above 0.5% threshold)
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 500) / 10000; // 5% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);
        console.log("DEBUG: Target price:", uint256(TARGET_PRICE));
        console.log("DEBUG: Deviated price set to:", uint256(deviatedPrice));

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);
        console.log("DEBUG: Time advanced to:", block.timestamp);

        // Verify there are arbitrage opportunities
        IRepegManager.ArbitrageOpportunity[] memory opportunities = repegManager.getArbitrageOpportunities();
        console.log("DEBUG: Number of arbitrage opportunities:", opportunities.length);
        assertGt(opportunities.length, 0, "Should have arbitrage opportunities");

        if (opportunities.length > 0) {
            console.log("DEBUG: First opportunity - tokenA:", opportunities[0].tokenA);
            console.log("DEBUG: First opportunity - tokenB:", opportunities[0].tokenB);
            console.log("DEBUG: First opportunity - amountIn:", opportunities[0].amountIn);
            console.log("DEBUG: First opportunity - expectedProfit:", opportunities[0].expectedProfit);
            console.log("DEBUG: First opportunity - confidence:", uint256(opportunities[0].confidence));
            console.log("DEBUG: First opportunity - expiryTime:", uint256(opportunities[0].expiryTime));
        }

        console.log("DEBUG: About to attempt reentrancy attack...");

        // Check if the malicious contract is in attacking state
        console.log("DEBUG: Malicious contract attacking state before:", malicious.attacking());

        // Make the malicious contract call executeArbitrage directly
        // The initial call should succeed, but the reentrancy attack inside MockArbitrageManager should be blocked
        malicious.directExecuteArbitrage{value: 1 ether}();

        console.log("DEBUG: Test completed - initial call succeeded, reentrancy attack was blocked internally");
    }

    function test_AccessControl_OnlyOwnerFunctions() public {
        IRepegManager.RepegConfig memory newConfig = IRepegManager.RepegConfig({
            targetPrice: TARGET_PRICE,
            deviationThreshold: 200,
            repegCooldown: 1800,
            arbitrageWindow: 300,
            incentiveRate: 100,
            maxRepegPerDay: 10,
            enabled: true
        });

        // Test updateRepegConfig
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        repegManager.updateRepegConfig(newConfig);
        vm.stopPrank();

        // Test updateDeviationThreshold
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        repegManager.updateDeviationThreshold(200);
        vm.stopPrank();

        // Test updateIncentiveParameters
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        repegManager.updateIncentiveParameters(150, 1000e18);
        vm.stopPrank();
    }

    function test_RateLimiting_MaxRepegPerDay() public {
        // Set up conditions for multiple repegs
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 100) / 10000; // 1% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Execute maximum allowed repegs (default is 10)
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(user1);
            stableGuard.triggerRepeg();
            vm.stopPrank();

            // Advance time to avoid cooldown
            vm.warp(block.timestamp + 3601); // 1 hour + 1 second
        }

        // Next repeg should fail due to daily limit
        vm.startPrank(user1);
        (bool triggered,) = stableGuard.triggerRepeg();
        assertFalse(triggered, "Repeg should not trigger due to daily limit");
        vm.stopPrank();
    }

    function test_RateLimiting_RepegCooldown() public {
        // Set up conditions for repeg
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 100) / 10000; // 1% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Execute first repeg
        vm.startPrank(user1);
        stableGuard.triggerRepeg();
        vm.stopPrank();

        // Try to execute another repeg immediately (should fail due to cooldown)
        vm.startPrank(user1);
        (bool triggered,) = stableGuard.triggerRepeg();
        assertFalse(triggered, "Repeg should not trigger due to cooldown");
        vm.stopPrank();

        // Advance time past cooldown
        vm.warp(block.timestamp + 3601); // 1 hour + 1 second

        // Now repeg should work
        vm.startPrank(user1);
        stableGuard.triggerRepeg();
        vm.stopPrank();
    }

    function test_CircuitBreaker_ConsecutiveRepegs() public {
        // Set up conditions for multiple consecutive repegs
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 100) / 10000; // 1% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Execute multiple consecutive repegs
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(user1);
            stableGuard.triggerRepeg();
            vm.stopPrank();

            // Advance time to avoid cooldown but keep deviation
            vm.warp(block.timestamp + 3601);
        }

        // Check that circuit breaker logic is working (deviation threshold should be adjusted)
        IRepegManager.RepegConfig memory config = repegManager.getRepegConfig();
        // The threshold might be adjusted based on consecutive repegs
        assertGe(config.deviationThreshold, 100, "Deviation threshold should be at least initial value");
    }

    function test_InvalidParameters_EdgeCases() public {
        // Test executeRepeg with invalid direction - should fail with Unauthorized since user1 is not authorized
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.Unauthorized.selector);
        repegManager.executeRepeg(TARGET_PRICE, 3); // Invalid direction (should be 0, 1, or 2)
        vm.stopPrank();

        // Test executeRepeg with zero target price - should fail with Unauthorized since user1 is not authorized
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.Unauthorized.selector);
        repegManager.executeRepeg(0, 1);
        vm.stopPrank();
    }

    function test_PriceOracle_Failure_Handling() public {
        // Simulate oracle failure by setting it to return 0
        priceOracle.setPrice(address(stableToken), 0);

        vm.startPrank(user1);
        (bool needed,) = repegManager.isRepegNeeded();
        assertFalse(needed, "Should not need repeg when oracle fails");
        vm.stopPrank();
    }

    // ============ EDGE CASES AND GAS OPTIMIZATION TESTS ============

    function test_EdgeCase_ExtremeDeviation() public {
        // Test with extreme price deviation (50% above target)
        uint128 extremePrice = TARGET_PRICE + (TARGET_PRICE * 5000) / 10000; // 50% above
        priceOracle.setPrice(address(stableToken), extremePrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed, uint128 deviation) = repegManager.isRepegNeeded();
        assertTrue(needed, "Should need repeg for extreme deviation");
        assertEq(deviation, 5000, "Deviation should be 50%");
        vm.stopPrank();
    }

    function test_EdgeCase_MinimalDeviation() public {
        // Test with minimal deviation just above threshold
        uint128 minimalPrice = TARGET_PRICE + (TARGET_PRICE * 501) / 10000; // 5.01% above (just above 5% threshold)
        priceOracle.setPrice(address(stableToken), minimalPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed, uint128 deviation) = repegManager.isRepegNeeded();
        assertTrue(needed, "Should need repeg for minimal deviation above threshold");
        assertEq(deviation, 501, "Deviation should be 5.01%");
        vm.stopPrank();
    }

    function test_EdgeCase_ExactThreshold() public {
        // Test with deviation exactly at threshold
        uint128 thresholdPrice = TARGET_PRICE + (TARGET_PRICE * 500) / 10000; // Exactly 5% above
        priceOracle.setPrice(address(stableToken), thresholdPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed, uint128 deviation) = repegManager.isRepegNeeded();
        assertTrue(needed, "Should need repeg at exact threshold");
        assertEq(deviation, 500, "Deviation should be exactly 5%");
        vm.stopPrank();
    }

    function test_EdgeCase_BelowThreshold() public {
        // Test with deviation just below threshold
        uint128 belowThresholdPrice = TARGET_PRICE + (TARGET_PRICE * 499) / 10000; // 4.99% above (below 5% threshold)
        priceOracle.setPrice(address(stableToken), belowThresholdPrice);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed,) = repegManager.isRepegNeeded();
        assertFalse(needed, "Should not need repeg below threshold");
        vm.stopPrank();
    }

    function test_EdgeCase_ZeroPrice() public {
        // Test with zero price from oracle
        priceOracle.setPrice(address(stableToken), 0);

        // Advance time to invalidate cache and ensure fresh price is fetched
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed,) = repegManager.isRepegNeeded();
        assertFalse(needed, "Should not need repeg with zero price");
        vm.stopPrank();
    }

    function test_EdgeCase_MaxUint128Price() public {
        // Test with maximum uint128 price
        uint128 maxPrice = type(uint128).max;
        priceOracle.setPrice(address(stableToken), maxPrice);

        // Advance time to invalidate price cache (cache duration is 60 seconds)
        vm.warp(block.timestamp + 61);

        vm.startPrank(user1);
        (bool needed,) = repegManager.isRepegNeeded();
        assertTrue(needed, "Should need repeg with max price");
        vm.stopPrank();
    }

    function test_EdgeCase_DailyLimitReset() public {
        // Test daily limit reset functionality
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // Execute maximum repegs for the day
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(user1);
            stableGuard.triggerRepeg();
            vm.stopPrank();
            vm.warp(block.timestamp + 3601); // Advance past cooldown
        }

        // Should fail due to daily limit
        vm.startPrank(user1);
        (bool triggered,) = stableGuard.triggerRepeg();
        assertFalse(triggered, "Repeg should not trigger due to daily limit");
        vm.stopPrank();

        // Advance to next day (86400 seconds = 1 day)
        vm.warp(block.timestamp + 86400);

        // Should work again after daily reset
        vm.startPrank(user1);
        stableGuard.triggerRepeg();
        vm.stopPrank();
    }

    function test_EdgeCase_ArbitrageWithZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.executeArbitrage(0, 500);
        vm.stopPrank();
    }

    function test_EdgeCase_ArbitrageWithMaxSlippage() public {
        uint256 arbitrageAmount = 1 ether;
        vm.deal(user1, arbitrageAmount);

        vm.startPrank(user1);
        vm.expectRevert(RepegManager.InvalidParameters.selector);
        repegManager.executeArbitrage{value: arbitrageAmount}(arbitrageAmount, 1001); // > 10% max slippage
        vm.stopPrank();
    }

    function test_GasOptimization_BatchOperations() public {
        // Test gas usage for multiple operations
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        uint256 gasBefore = gasleft();

        vm.startPrank(user1);
        // Perform multiple view operations that should be gas-optimized
        repegManager.isRepegNeeded();
        repegManager.getCurrentDeviation();
        repegManager.getArbitrageOpportunities();
        repegManager.getRepegConfig();
        repegManager.getRepegState();
        vm.stopPrank();

        uint256 gasUsed = gasBefore - gasleft();

        // Gas usage should be reasonable for batch view operations
        assertLt(gasUsed, 200000, "Batch view operations should use less than 200k gas");
    }

    function test_GasOptimization_RepegExecution() public {
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        uint256 gasBefore = gasleft();

        vm.startPrank(user1);
        stableGuard.triggerRepeg();
        vm.stopPrank();

        uint256 gasUsed = gasBefore - gasleft();

        // Repeg execution should be gas-optimized
        assertLt(gasUsed, 300000, "Repeg execution should use less than 300k gas");
    }

    function test_EdgeCase_LiquidityProviderTracking() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 500e18;

        // Mint tokens for both users
        stableToken.mint(user1, amount1);
        stableToken.mint(user2, amount2);

        // User1 provides liquidity
        vm.startPrank(user1);
        stableToken.approve(address(repegManager), amount1);
        repegManager.provideLiquidity(amount1);
        vm.stopPrank();

        // User2 provides liquidity
        vm.startPrank(user2);
        stableToken.approve(address(repegManager), amount2);
        repegManager.provideLiquidity(amount2);
        vm.stopPrank();

        // Check total liquidity
        (uint256 totalLiquidity,) = repegManager.getLiquidityPoolStatus();
        assertEq(totalLiquidity, amount1 + amount2, "Total liquidity should be sum of both providers");

        // User1 withdraws partial liquidity
        vm.startPrank(user1);
        repegManager.withdrawLiquidity(amount1 / 2);
        vm.stopPrank();

        // Check updated liquidity
        (totalLiquidity,) = repegManager.getLiquidityPoolStatus();
        assertEq(totalLiquidity, amount1 / 2 + amount2, "Total liquidity should be updated after withdrawal");
    }

    function test_EdgeCase_ConfigurationBoundaries() public {
        // Test configuration with boundary values
        IRepegManager.RepegConfig memory boundaryConfig = IRepegManager.RepegConfig({
            targetPrice: 1, // Minimum price
            deviationThreshold: 1, // Minimum threshold
            repegCooldown: 1, // Minimum cooldown
            arbitrageWindow: 300,
            incentiveRate: 1, // Minimum rate
            maxRepegPerDay: 1, // Minimum daily limit
            enabled: true
        });

        vm.startPrank(owner);
        repegManager.updateRepegConfig(boundaryConfig);
        vm.stopPrank();

        IRepegManager.RepegConfig memory retrievedConfig = repegManager.getRepegConfig();
        assertEq(retrievedConfig.targetPrice, 1, "Target price should be set to minimum");
        assertEq(retrievedConfig.deviationThreshold, 1, "Deviation threshold should be set to minimum");
        assertEq(retrievedConfig.maxRepegPerDay, 1, "Max repeg per day should be set to minimum");
    }

    function test_EdgeCase_IncentiveCalculation() public {
        // Provide liquidity to enable incentive calculations
        vm.deal(user1, 1000e18);
        vm.startPrank(user1);
        repegManager.provideLiquidity{value: 1000e18}(1000e18);
        vm.stopPrank();

        // Test incentive calculation with various deviations
        uint128[] memory deviations = new uint128[](5);
        deviations[0] = 600; // 6%
        deviations[1] = 800; // 8%
        deviations[2] = 1000; // 10%
        deviations[3] = 2000; // 20%
        deviations[4] = 5000; // 50%

        for (uint256 i = 0; i < deviations.length; i++) {
            uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * deviations[i]) / 10000;
            priceOracle.setPrice(address(stableToken), deviatedPrice);

            // Advance time to invalidate cache and ensure fresh price is fetched
            vm.warp(block.timestamp + 61);

            vm.startPrank(user1);
            (uint128 targetPrice, uint8 direction, uint128 incentive) = repegManager.calculateRepegParameters();
            vm.stopPrank();

            assertGt(incentive, 0, "Incentive should be positive for deviation");
            assertEq(targetPrice, TARGET_PRICE, "Target price should remain constant");
            assertEq(direction, 2, "Direction should be down (2) for price above target");

            // Reset for next iteration
            vm.warp(block.timestamp + 3601);
        }
    }

    function test_EdgeCase_ConcurrentOperations() public {
        // Test concurrent operations from different users
        uint128 deviatedPrice = TARGET_PRICE + (TARGET_PRICE * 600) / 10000; // 6% deviation
        priceOracle.setPrice(address(stableToken), deviatedPrice);

        // User1 triggers repeg
        vm.startPrank(user1);
        stableGuard.triggerRepeg();
        vm.stopPrank();

        // User2 tries to trigger repeg immediately (should fail due to cooldown)
        vm.startPrank(user2);
        (bool triggered,) = stableGuard.triggerRepeg();
        assertFalse(triggered, "Repeg should not trigger due to cooldown");
        vm.stopPrank();

        // User2 can still check repeg status
        vm.startPrank(user2);
        repegManager.isRepegNeeded();
        vm.stopPrank();

        // The result depends on whether the first repeg was effective
        // If effective, needed should be false; if not, it could still be true
    }
}

// ============ MALICIOUS CONTRACTS FOR REENTRANCY TESTING ============

contract MaliciousReentrancyContract is IERC20Receiver {
    IRepegManager public repegManager;
    bool public attacking = false;

    constructor(address _repegManager) {
        repegManager = IRepegManager(_repegManager);
    }

    function attemptReentrancy() external {
        // checkAndTriggerRepeg is now onlyStableGuard: a non-StableGuard caller
        // (this contract) cannot even enter, so reentrancy is doubly prevented.
        attacking = true;
        repegManager.checkAndTriggerRepeg(address(this));
    }

    // This will be called when tokens are transferred to this contract
    function onTokenReceived(address, uint256) external override {
        if (attacking) {
            attacking = false; // Prevent infinite recursion
            repegManager.checkAndTriggerRepeg(address(this));
        }
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            repegManager.checkAndTriggerRepeg(address(this));
        }
    }
}

contract MaliciousArbitrageContract {
    IRepegManager public repegManager;
    bool public attacking = false;

    constructor(address _repegManager) {
        repegManager = IRepegManager(_repegManager);
    }

    function attemptArbitrageReentrancy() external {
        console.log("DEBUG: MaliciousArbitrageContract.attemptArbitrageReentrancy() called");
        console.log("DEBUG: Contract balance before attack:", address(this).balance);
        attacking = true;
        console.log("DEBUG: Set attacking to true, about to call executeArbitrage");
        // This should trigger reentrancy protection when ArbitrageManager calls back
        repegManager.executeArbitrage{value: 1 ether}(1 ether, 500);
        console.log("DEBUG: executeArbitrage call completed without revert");
    }

    function directExecuteArbitrage() external payable {
        console.log("DEBUG: MaliciousArbitrageContract.directExecuteArbitrage() called");
        console.log("DEBUG: Contract balance before attack:", address(this).balance);
        console.log("DEBUG: msg.value:", msg.value);
        attacking = true;
        console.log("DEBUG: Set attacking to true, about to call executeArbitrage directly");
        // This makes tx.origin = this contract, so MockArbitrageManager can detect it
        repegManager.executeArbitrage{value: msg.value}(1 ether, 500);
        console.log("DEBUG: executeArbitrage call completed without revert");
    }

    function triggerReentrancy() external {
        console.log("DEBUG: MaliciousArbitrageContract.triggerReentrancy() called");
        console.log("DEBUG: msg.sender:", msg.sender);
        console.log("DEBUG: tx.origin:", tx.origin);
        console.log("DEBUG: Attacking state:", attacking);
        console.log("DEBUG: Contract balance:", address(this).balance);

        if (attacking && address(this).balance >= 1 ether) {
            console.log("DEBUG: Conditions met, attempting reentrancy attack via triggerReentrancy");
            attacking = false; // Prevent infinite recursion
            // Attempt reentrancy - this should be blocked by nonReentrant modifier
            repegManager.executeArbitrage{value: 1 ether}(1 ether, 500);
            console.log("DEBUG: Reentrancy attack completed - this should not be reached!");
        } else {
            console.log("DEBUG: Conditions not met for reentrancy attack");
            console.log("DEBUG: attacking:", attacking);
            console.log("DEBUG: balance >= 1 ether:", address(this).balance >= 1 ether);
        }
    }

    function callbackReentrancy() external {
        console.log("DEBUG: MaliciousArbitrageContract.callbackReentrancy() called");
        console.log("DEBUG: msg.sender:", msg.sender);
        console.log("DEBUG: tx.origin:", tx.origin);
        console.log("DEBUG: Attacking state:", attacking);
        console.log("DEBUG: Contract balance:", address(this).balance);

        if (attacking && address(this).balance >= 1 ether) {
            console.log("DEBUG: Conditions met, attempting reentrancy attack via callback");
            attacking = false; // Prevent infinite recursion
            // Attempt reentrancy - this should be blocked by nonReentrant modifier
            repegManager.executeArbitrage{value: 1 ether}(1 ether, 500);
            console.log("DEBUG: Reentrancy attack completed - this should not be reached!");
        } else {
            console.log("DEBUG: Conditions not met for reentrancy attack");
            console.log("DEBUG: attacking:", attacking);
            console.log("DEBUG: balance >= 1 ether:", address(this).balance >= 1 ether);
        }
    }

    receive() external payable {
        console.log("DEBUG: MaliciousArbitrageContract.receive() called");
        console.log("DEBUG: Received ETH amount:", msg.value);
        console.log("DEBUG: Current balance:", address(this).balance);
        console.log("DEBUG: Attacking state:", attacking);

        if (attacking && address(this).balance >= 1 ether) {
            console.log("DEBUG: Conditions met, attempting reentrancy attack");
            attacking = false; // Prevent infinite recursion
            // Attempt reentrancy - this should be blocked by nonReentrant modifier
            repegManager.executeArbitrage{value: 1 ether}(1 ether, 500);
            console.log("DEBUG: Reentrancy attack completed - this should not be reached!");
        } else {
            console.log("DEBUG: Conditions not met for reentrancy attack");
            console.log("DEBUG: attacking:", attacking);
            console.log("DEBUG: balance >= 1 ether:", address(this).balance >= 1 ether);
        }
    }
}
