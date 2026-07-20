// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IArbitrageManager} from "./interfaces/IArbitrageManager.sol";
import {Constants} from "./Constants.sol";

/**
 * @title ArbitrageManager
 * @dev Manages arbitrage opportunities between different DEXs for price stabilization
 */
contract ArbitrageManager is IArbitrageManager, Ownable, ReentrancyGuard {
    // ============ PACKED STRUCTS FOR GAS OPTIMIZATION ============

    struct PackedPriceData {
        uint128 chainlinkPrice;
        uint128 dexPrice;
    }

    struct PackedArbitrageState {
        uint64 lastArbitrageTime;
        uint64 lastUpdateTime;
        uint128 totalProfit;
    }

    // ============ IMMUTABLE VARIABLES ============

    // DEX Router - focused on Uniswap V2 for simplicity
    address public immutable UNISWAP_V2_ROUTER;

    // Price Oracle for reliable Chainlink pricing
    IPriceOracle public immutable PRICE_ORACLE;

    // Token addresses
    address public immutable WETH;
    address public immutable STABLE_TOKEN;

    // ============ CACHED CONSTANTS ============

    // ============ PACKED STATE VARIABLES ============

    // Arbitrage configuration
    IArbitrageManager.ArbitrageConfig public config;

    // Packed price and state data
    PackedPriceData private _priceCache;
    PackedArbitrageState private _arbitrageState;

    // Cached trading paths for gas optimization
    address[] private _buyPath;
    address[] private _sellPath;

    // Price tracking with packed storage
    mapping(address => uint128) public lastPrices; // DEX => last price

    // ============ SECURITY ENHANCEMENTS ============

    // Circuit breaker for external calls
    struct CircuitBreakerState {
        uint64 failureCount;
        uint64 lastFailureTime;
        uint64 lastSuccessTime;
        bool isTripped;
    }

    CircuitBreakerState private _circuitBreaker;

    // Gas limits for external calls
    uint256 private constant MAX_EXTERNAL_CALL_GAS = 300000;
    uint256 private constant MAX_SWAP_GAS = 200000;

    // Circuit breaker thresholds
    uint256 private constant FAILURE_THRESHOLD = 3;
    uint256 private constant RECOVERY_TIME = 1 hours;

    // Rate limiting
    mapping(address => uint256) private _lastOperationTime;
    uint256 private constant OPERATION_COOLDOWN = Constants.ARBITRAGE_COOLDOWN; // per-user cooldown

    // ============ MODIFIERS WITH ASSEMBLY OPTIMIZATION ============

    modifier onlyWhenEnabled() {
        require(config.enabled, "Arbitrage disabled");
        _;
    }

    modifier rateLimited() {
        require(block.timestamp >= _lastOperationTime[msg.sender] + OPERATION_COOLDOWN, "Rate limit exceeded");
        _lastOperationTime[msg.sender] = block.timestamp;
        _;
    }

    modifier circuitBreakerCheck() {
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");
        _;
    }

    // ============ SECURITY FUNCTIONS ============

    /**
     * @dev Public function to test DEX connectivity and update circuit breaker
     * This allows the circuit breaker to be updated in a separate transaction
     */
    function updateCircuitBreakerState() external {
        // Test DEX connectivity directly without circuit breaker check
        // This allows recovery from tripped state
        bytes memory getAmountsData = abi.encodeWithSignature("getAmountsOut(uint256,address[])", 1 ether, _buyPath);

        // Direct call without circuit breaker check
        (bool success, bytes memory result) = UNISWAP_V2_ROUTER.staticcall{gas: MAX_EXTERNAL_CALL_GAS}(getAmountsData);

        bool dexPriceValid = false;
        if (success) {
            uint256[] memory amounts = abi.decode(result, (uint256[]));
            dexPriceValid = (amounts.length == 2 && amounts[1] > 0);
        }

        _updateCircuitBreaker(dexPriceValid);
    }

    /**
     * @dev Check and update circuit breaker state
     */
    function _updateCircuitBreaker(bool success) internal {
        if (success) {
            _circuitBreaker.lastSuccessTime = uint64(block.timestamp);
            // Reset failure count on success
            if (_circuitBreaker.failureCount > 0) {
                _circuitBreaker.failureCount = 0;
            }
            // Check if we can recover from tripped state
            if (_circuitBreaker.isTripped && block.timestamp >= _circuitBreaker.lastFailureTime + RECOVERY_TIME) {
                _circuitBreaker.isTripped = false;
            }
        } else {
            _circuitBreaker.failureCount++;
            _circuitBreaker.lastFailureTime = uint64(block.timestamp);

            // Trip circuit breaker if threshold reached
            if (_circuitBreaker.failureCount >= FAILURE_THRESHOLD) {
                _circuitBreaker.isTripped = true;
            }
        }
    }

    /**
     * @dev Safe external call with gas limit and circuit breaker
     */
    function _safeExternalCall(address target, bytes memory data, uint256 gasLimit)
        internal
        returns (bool success, bytes memory result)
    {
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");

        // Limit gas to prevent griefing
        uint256 actualGasLimit = gasLimit > MAX_EXTERNAL_CALL_GAS ? MAX_EXTERNAL_CALL_GAS : gasLimit;

        (success, result) = target.call{gas: actualGasLimit}(data);

        // Update circuit breaker state
        _updateCircuitBreaker(success);

        return (success, result);
    }

    /**
     * @dev Safe external call with value and gas limit
     */
    function _safeExternalCallWithValue(address target, bytes memory data, uint256 value, uint256 gasLimit)
        internal
        returns (bool success, bytes memory result)
    {
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");

        // Limit gas to prevent griefing
        uint256 actualGasLimit = gasLimit > MAX_EXTERNAL_CALL_GAS ? MAX_EXTERNAL_CALL_GAS : gasLimit;

        (success, result) = target.call{value: value, gas: actualGasLimit}(data);

        // Update circuit breaker state
        _updateCircuitBreaker(success);

        return (success, result);
    }

    /**
     * @dev Safe static call with gas limit and circuit breaker
     */
    function _safeStaticCall(address target, bytes memory data)
        internal
        view
        returns (bool success, bytes memory result)
    {
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");

        (success, result) = target.staticcall{gas: MAX_EXTERNAL_CALL_GAS}(data);

        // Don't update circuit breaker here - let caller handle it

        return (success, result);
    }

    // Events are inherited from IArbitrageManager interface

    constructor(address _uniswapV2Router, address _priceOracle, address _weth, address _stableToken)
        Ownable(msg.sender)
    {
        require(_uniswapV2Router != address(0), "Zero router address");
        require(_priceOracle != address(0), "Zero oracle address");
        require(_weth != address(0), "Zero WETH address");
        require(_stableToken != address(0), "Zero token address");

        UNISWAP_V2_ROUTER = _uniswapV2Router;
        PRICE_ORACLE = IPriceOracle(_priceOracle);
        WETH = _weth;
        STABLE_TOKEN = _stableToken;

        // Initialize packed state
        _arbitrageState =
            PackedArbitrageState({lastArbitrageTime: 0, lastUpdateTime: uint64(block.timestamp), totalProfit: 0});

        // Pre-calculate and cache trading paths
        _buyPath = new address[](2);
        _buyPath[0] = _weth;
        _buyPath[1] = _stableToken;

        _sellPath = new address[](2);
        _sellPath[0] = _stableToken;
        _sellPath[1] = _weth;

        // Default configuration
        config = IArbitrageManager.ArbitrageConfig({
            maxTradeSize: 100 ether, // 100 ETH max per trade
            minProfitBps: Constants.MIN_ARBITRAGE_PROFIT,
            maxSlippageBps: Constants.MAX_ARBITRAGE_SLIPPAGE,
            enabled: true
        });
    }

    // ============ PRICE CACHING FUNCTIONS ============

    function _updatePriceCache() private {
        uint256 chainlinkPrice = PRICE_ORACLE.getTokenPrice(STABLE_TOKEN);
        uint256 dexPrice = _getUniswapV2PriceCached();

        _priceCache = PackedPriceData({chainlinkPrice: uint128(chainlinkPrice), dexPrice: uint128(dexPrice)});
    }

    function _getPriceCacheIfFresh() private view returns (PackedPriceData memory priceData, bool isFresh) {
        // Consider cache fresh if updated within last 30 seconds
        isFresh = (block.timestamp - _arbitrageState.lastUpdateTime) < 30;
        priceData = _priceCache;
    }

    /**
     * @dev Scans for arbitrage opportunities and executes profitable trades
     * Uses Chainlink for reliable pricing and compares with DEX prices
     */
    function executeArbitrage() external override nonReentrant onlyWhenEnabled rateLimited {
        // Check circuit breaker first
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");

        // Get prices with caching
        PackedPriceData memory prices;

        (PackedPriceData memory cachedPrices, bool isFresh) = _getPriceCacheIfFresh();
        if (!isFresh) {
            // Update the cache with fresh prices
            uint256 chainlinkPrice = PRICE_ORACLE.getTokenPrice(STABLE_TOKEN);
            uint256 dexPrice = _getUniswapV2PriceCached();

            _priceCache = PackedPriceData({chainlinkPrice: uint128(chainlinkPrice), dexPrice: uint128(dexPrice)});

            // Update arbitrage state timestamp
            assembly {
                let stateSlot := _arbitrageState.slot
                let currentState := sload(stateSlot)
                let currentTime := timestamp()

                // Update only the lastUpdateTime (bits 64-127)
                let clearedState := and(currentState, not(shl(64, 0xFFFFFFFFFFFFFFFF)))
                let newState := or(clearedState, shl(64, currentTime))
                sstore(stateSlot, newState)
            }

            prices = _priceCache;
        } else {
            prices = cachedPrices;
        }

        // Validate prices in consistent order: oracle first, then DEX
        require(prices.chainlinkPrice > 0, "Invalid oracle price");
        require(prices.dexPrice > 0, "Invalid DEX price");

        // Update circuit breaker based on successful price fetching
        _updateCircuitBreaker(true);

        // Check if circuit breaker is tripped after validation
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");

        // Calculate price difference with assembly optimization
        uint256 priceDifference;
        bool shouldBuyFromDex;

        assembly {
            let chainlink := mload(add(prices, 0x00))
            let dex := mload(add(prices, 0x20))

            if lt(dex, chainlink) {
                priceDifference := sub(chainlink, dex)
                shouldBuyFromDex := 1
            }
            if gt(dex, chainlink) {
                priceDifference := sub(dex, chainlink)
                shouldBuyFromDex := 0
            }
        }

        // Calculate profit percentage with cached basis points
        uint256 profitBps = (priceDifference * Constants.BASIS_POINTS) / prices.chainlinkPrice;

        // Check if arbitrage is profitable
        require(profitBps >= config.minProfitBps, "Insufficient profit");

        // Calculate optimal trade size
        uint256 tradeSize = _calculateOptimalTradeSize(profitBps);
        require(tradeSize > 0, "No viable trade size");

        // Execute the arbitrage trade
        uint256 profit = _executeArbitrageTrade(tradeSize, shouldBuyFromDex, prices);

        // Update circuit breaker with success
        _updateCircuitBreaker(true);

        // Update state with assembly optimization
        assembly {
            let stateSlot := _arbitrageState.slot
            let currentTime := timestamp()

            // Read current packed state
            let currentState := sload(stateSlot)

            // Extract totalProfit from bits 128-255 (upper 128 bits)
            let currentTotalProfit := shr(128, currentState)
            let newTotalProfit := add(currentTotalProfit, profit)

            // Pack: lastArbitrageTime (64) + lastUpdateTime (64) + totalProfit (128)
            let packedState := or(or(currentTime, shl(64, currentTime)), shl(128, newTotalProfit))
            sstore(stateSlot, packedState)
        }

        // Calculate amountOut based on the trade direction and profit
        uint256 amountOut = shouldBuyFromDex
            ? (tradeSize * prices.dexPrice) / Constants.PRICE_PRECISION
            : (tradeSize * Constants.PRICE_PRECISION) / prices.dexPrice;

        emit ArbitrageExecuted(
            UNISWAP_V2_ROUTER, // dexFrom - always Uniswap V2 (the only DEX)
            UNISWAP_V2_ROUTER, // dexTo - always Uniswap V2 (the only DEX)
            tradeSize, // amountIn
            amountOut, // amountOut
            profit, // profit
            block.timestamp // timestamp
        );
    }

    // Note: _findBestArbitrage function removed - focusing on simple V2 implementation

    /**
     * @dev Execute arbitrage trade using Uniswap V2
     * @param tradeSize Amount to trade
     * @param shouldBuyFromDex Whether to buy from DEX (true) or sell to DEX (false)
     * @param prices Cached price data
     * @return profit The profit made from the arbitrage
     */
    function _executeArbitrageTrade(uint256 tradeSize, bool shouldBuyFromDex, PackedPriceData memory prices)
        internal
        returns (uint256 profit)
    {
        uint256 initialBalance = address(this).balance;

        if (shouldBuyFromDex) {
            // Buy tokens from DEX when DEX price is lower than oracle price
            uint256 tokensReceived = _buyFromUniswapV2Cached(tradeSize);

            if (tokensReceived > 0) {
                // Sell tokens back to DEX
                _sellToUniswapV2Cached(tokensReceived);
            }
        } else {
            // Sell tokens to DEX when DEX price is higher than oracle price
            // First need to have tokens to sell - buy them at oracle price (simulated)
            uint256 tokensToSell = (tradeSize * Constants.PRICE_PRECISION) / prices.chainlinkPrice;

            // Check if we have enough tokens
            uint256 tokenBalance = IERC20(STABLE_TOKEN).balanceOf(address(this));
            if (tokenBalance >= tokensToSell) {
                _sellToUniswapV2Cached(tokensToSell);
            }
        }

        // Calculate actual profit based on balance difference
        uint256 finalBalance = address(this).balance;
        profit = finalBalance > initialBalance ? finalBalance - initialBalance : 0;

        return profit;
    }

    /**
     * @dev Get current price from Uniswap V2 using cached path
     * @return price Current price of STABLE_TOKEN in ETH
     */
    function _getUniswapV2PriceCached() internal view returns (uint256 price) {
        // Get price for 1 ETH worth of tokens using cached path
        bytes memory getAmountsData = abi.encodeWithSignature("getAmountsOut(uint256,address[])", 1 ether, _buyPath);

        (bool success, bytes memory result) = _safeStaticCall(UNISWAP_V2_ROUTER, getAmountsData);

        if (!success) return 0;

        uint256[] memory amounts = abi.decode(result, (uint256[]));
        if (amounts.length != 2 || amounts[1] == 0) return 0;

        // Calculate price: ETH per token
        price = (1 ether * Constants.PRICE_PRECISION) / amounts[1];

        return price;
    }

    /**
     * @dev Get current price from Uniswap V2 (legacy function for compatibility)
     * @return price Current price of STABLE_TOKEN in ETH
     */
    function _getUniswapV2Price() internal view returns (uint256 price) {
        return _getUniswapV2PriceCached();
    }

    /**
     * @dev Buy tokens from Uniswap V2 using cached paths (optimized)
     */
    function _buyFromUniswapV2Cached(uint256 ethAmount) internal returns (uint256) {
        require(ethAmount > 0, "Invalid ETH amount");
        require(address(this).balance >= ethAmount, "Insufficient ETH balance");

        // Get expected output amount using cached path
        bytes memory getAmountsData = abi.encodeWithSignature("getAmountsOut(uint256,address[])", ethAmount, _buyPath);

        (bool success, bytes memory result) = _safeStaticCall(UNISWAP_V2_ROUTER, getAmountsData);
        require(success, "Failed to get amounts out");

        uint256[] memory amounts = abi.decode(result, (uint256[]));
        require(amounts.length == 2 && amounts[1] > 0, "Invalid amounts returned");

        // Calculate minimum tokens with slippage protection using cached basis points
        uint256 minTokens = (amounts[1] * (Constants.BASIS_POINTS - config.maxSlippageBps)) / Constants.BASIS_POINTS;
        require(minTokens > 0, "Minimum tokens too low");

        // Execute swap with deadline protection using cached path
        bytes memory swapData = abi.encodeWithSignature(
            "swapExactEthForTokens(uint256,address[],address,uint256)",
            minTokens,
            _buyPath,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        );

        (bool swapSuccess, bytes memory swapResult) =
            _safeExternalCallWithValue(UNISWAP_V2_ROUTER, swapData, ethAmount, MAX_SWAP_GAS);
        require(swapSuccess, "Swap failed");

        uint256[] memory swapAmounts = abi.decode(swapResult, (uint256[]));
        require(swapAmounts.length >= 2, "Invalid swap result");

        return swapAmounts[swapAmounts.length - 1]; // Return final amount
    }

    /**
     * @dev Buy tokens from Uniswap V2 (legacy function for compatibility)
     */
    function _buyFromUniswapV2(uint256 ethAmount) internal returns (uint256) {
        return _buyFromUniswapV2Cached(ethAmount);
    }

    // Note: Uniswap V3 functions removed for simplicity - focusing on V2 only

    /**
     * @dev Sell tokens to Uniswap V2 using cached paths (optimized)
     */
    function _sellToUniswapV2Cached(uint256 tokenAmount) internal returns (uint256) {
        require(tokenAmount > 0, "Invalid token amount");
        require(IERC20(STABLE_TOKEN).balanceOf(address(this)) >= tokenAmount, "Insufficient token balance");

        // Approve router to spend tokens
        IERC20(STABLE_TOKEN).approve(UNISWAP_V2_ROUTER, tokenAmount);

        // Get expected output amount using cached path
        bytes memory getAmountsData =
            abi.encodeWithSignature("getAmountsOut(uint256,address[])", tokenAmount, _sellPath);

        (bool success, bytes memory result) = _safeStaticCall(UNISWAP_V2_ROUTER, getAmountsData);
        require(success, "Failed to get amounts out");

        uint256[] memory amounts = abi.decode(result, (uint256[]));
        require(amounts.length == 2 && amounts[1] > 0, "Invalid amounts returned");

        // Calculate minimum ETH with slippage protection using cached basis points
        uint256 minEth = (amounts[1] * (Constants.BASIS_POINTS - config.maxSlippageBps)) / Constants.BASIS_POINTS;
        require(minEth > 0, "Minimum ETH too low");

        // Execute swap with deadline protection using cached path
        bytes memory swapData = abi.encodeWithSignature(
            "swapExactTokensForEth(uint256,uint256,address[],address,uint256)",
            tokenAmount,
            minEth,
            _sellPath,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        );

        (bool swapSuccess, bytes memory swapResult) = _safeExternalCall(UNISWAP_V2_ROUTER, swapData, MAX_SWAP_GAS);
        require(swapSuccess, "Swap failed");

        uint256[] memory swapAmounts = abi.decode(swapResult, (uint256[]));
        require(swapAmounts.length >= 2, "Invalid swap result");

        return swapAmounts[swapAmounts.length - 1]; // Return final ETH amount
    }

    /**
     * @dev Sell tokens to Uniswap V2 (legacy function for compatibility)
     */
    function _sellToUniswapV2(uint256 tokenAmount) internal returns (uint256) {
        return _sellToUniswapV2Cached(tokenAmount);
    }

    // Note: Price fetching removed - using Chainlink oracle via PriceOracle contract for reliable pricing

    /**
     * @dev Calculate optimal trade size based on price difference and available liquidity (optimized)
     */
    function _calculateOptimalTradeSize(uint256 profitBps) internal view returns (uint256) {
        // Get available ETH balance
        uint256 availableBalance = address(this).balance;

        // Check if we have any balance to trade with
        require(availableBalance > 0, "No viable trade size");

        // Use smaller of: available balance or max trade size
        uint256 maxPossible = availableBalance < config.maxTradeSize ? availableBalance : config.maxTradeSize;

        // Calculate optimal size based on profit percentage (higher profit = larger trade)
        uint256 profitMultiplier = profitBps > config.minProfitBps ? (profitBps * 100) / config.minProfitBps : 100;
        uint256 tradeSize = (maxPossible * profitMultiplier) / 500; // Scale down for safety

        // Ensure minimum viable trade size (0.01 ETH)
        uint256 minTradeSize = 0.01 ether;

        // Cap at maximum possible
        if (tradeSize > maxPossible) {
            tradeSize = maxPossible;
        }

        return tradeSize > minTradeSize ? tradeSize : minTradeSize;
    }

    /// @inheritdoc IArbitrageManager
    function checkArbitrageOpportunity() external view override returns (bool exists, uint256 expectedProfit) {
        if (!config.enabled) return (false, 0);

        // Get cached prices for view function compatibility
        (PackedPriceData memory priceData, bool isFresh) = _getPriceCacheIfFresh();

        // If cache is not fresh, return false to avoid stale data
        if (!isFresh) return (false, 0);

        uint256 chainlinkPrice = uint256(priceData.chainlinkPrice);
        uint256 dexPrice = uint256(priceData.dexPrice);

        if (chainlinkPrice == 0 || dexPrice == 0) return (false, 0);

        // Calculate price difference
        uint256 priceDifference;
        if (dexPrice < chainlinkPrice) {
            priceDifference = chainlinkPrice - dexPrice;
        } else if (dexPrice > chainlinkPrice) {
            priceDifference = dexPrice - chainlinkPrice;
        } else {
            return (false, 0);
        }

        // Calculate expected profit percentage using cached constant
        expectedProfit = (priceDifference * Constants.BASIS_POINTS) / chainlinkPrice;
        exists = expectedProfit >= config.minProfitBps;

        return (exists, expectedProfit);
    }

    /// @inheritdoc IArbitrageManager
    function getConfig() external view override returns (IArbitrageManager.ArbitrageConfig memory) {
        return config;
    }

    /// @inheritdoc IArbitrageManager
    function getLastArbitrageTime() external view override returns (uint256) {
        return _arbitrageState.lastArbitrageTime;
    }

    /// @inheritdoc IArbitrageManager
    function getCurrentDexPrice() external view override returns (uint256) {
        return _getUniswapV2PriceCached();
    }

    /// @inheritdoc IArbitrageManager
    function updateConfig(uint256 _maxTradeSize, uint256 _minProfitBps, uint256 _maxSlippageBps, bool _enabled)
        external
        override
        onlyOwner
    {
        config = IArbitrageManager.ArbitrageConfig({
            maxTradeSize: _maxTradeSize, minProfitBps: _minProfitBps, maxSlippageBps: _maxSlippageBps, enabled: _enabled
        });

        emit ConfigUpdated(_maxTradeSize, _minProfitBps, _maxSlippageBps, _enabled);
    }

    /// @inheritdoc IArbitrageManager
    function emergencyWithdraw(address token) external override onlyOwner nonReentrant {
        if (token == address(0)) {
            uint256 balance = address(this).balance;
            require(balance > 0, "No ETH to withdraw");
            (bool success,) = payable(owner()).call{value: balance}("");
            require(success, "ETH transfer failed");
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            require(balance > 0, "No tokens to withdraw");
            require(IERC20(token).transfer(owner(), balance), "Token transfer failed");
        }
    }

    /**
     * @dev Reset circuit breaker state (for testing purposes)
     */
    function resetCircuitBreaker() external onlyOwner {
        _circuitBreaker.failureCount = 0;
        _circuitBreaker.lastFailureTime = 0;
        _circuitBreaker.lastSuccessTime = uint64(block.timestamp);
        _circuitBreaker.isTripped = false;
    }

    /**
     * @dev Update price cache manually - primarily for testing
     * @notice This function updates the price cache and timestamp for testing purposes
     */
    function updatePriceCache() external {
        _updatePriceCache();

        // Update the lastUpdateTime in the arbitrage state
        assembly {
            let stateSlot := _arbitrageState.slot
            let stateData := sload(stateSlot)
            let currentTime := timestamp()

            // Clear the lastUpdateTime bits (bits 64-127) and set new time
            let clearedState := and(stateData, 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            let newState := or(clearedState, shl(64, currentTime))
            sstore(stateSlot, newState)
        }
    }

    /**
     * @dev Get circuit breaker state for testing purposes
     * @return failureCount Number of consecutive failures
     * @return lastFailureTime Timestamp of last failure
     * @return lastSuccessTime Timestamp of last success
     * @return isTripped Whether circuit breaker is currently tripped
     */
    function getCircuitBreakerState()
        external
        view
        returns (uint256 failureCount, uint256 lastFailureTime, uint256 lastSuccessTime, bool isTripped)
    {
        return (
            _circuitBreaker.failureCount,
            _circuitBreaker.lastFailureTime,
            _circuitBreaker.lastSuccessTime,
            _circuitBreaker.isTripped
        );
    }

    // Receive ETH
    receive() external payable {}
}
