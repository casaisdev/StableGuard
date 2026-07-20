// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IRepegManager} from "./interfaces/IRepegManager.sol";
import {IArbitrageManager} from "./interfaces/IArbitrageManager.sol";
import {Constants} from "./Constants.sol";

/**
 * @title RepegManager - Ultra Gas Optimized Re-peg Mechanism
 * @dev Automatic price stabilization with advanced arbitrage detection and incentive system
 * @author StableGuard Protocol
 */
contract RepegManager is ReentrancyGuard, Ownable, IRepegManager {
    // ============ CONSTANTS ============
    uint256 private constant MAX_DEVIATION = 2000; // 20% max deviation
    uint256 private constant MIN_LIQUIDITY = 1000e18; // Minimum liquidity required
    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant MAX_INCENTIVE = 100e18; // Max incentive per repeg

    // ============ STRUCTS FOR GAS OPTIMIZATION ============

    // Pack emergency controls and price buffer together (32 bytes)
    struct PackedEmergencyData {
        bool emergencyPaused; // 1 byte
        uint128 priceBuffer; // 16 bytes
        uint64 lastEmergencyTime; // 8 bytes
        uint8 historyIndex; // 1 byte
        // 6 bytes padding
    }

    // Pack price history entry (32 bytes)
    struct PackedPriceHistory {
        uint128 price; // 16 bytes
        uint64 timestamp; // 8 bytes
        uint64 reserved; // 8 bytes for future use
    }

    // ============ ERRORS ============

    error Unauthorized();
    error InvalidParameters();
    error InvalidAddress();
    error InvalidThreshold();
    error TransferFailed();
    error InsufficientLiquidity();
    error RepegInProgress();
    error EmergencyPaused();
    error ArbitrageWindowExpired();

    // ============ IMMUTABLES ============
    address public immutable STABLE_GUARD;
    IPriceOracle public immutable PRICE_ORACLE;
    IERC20 public immutable STABLE_TOKEN;
    IArbitrageManager public immutable ARBITRAGE_MANAGER;

    // ============ OPTIMIZED STATE VARIABLES ============
    IRepegManager.RepegConfig private _config;
    IRepegManager.RepegState private _state;

    // Liquidity management: ETH and SGD are tracked separately so each provider
    // is repaid in the asset they deposited.
    uint256 private _totalEthLiquidity;
    uint256 private _totalSgdLiquidity;
    uint256 private _reservedLiquidity;
    mapping(address => uint256) private _ethLiquidity;
    mapping(address => uint256) private _sgdLiquidity;

    // Gas optimized packed data
    PackedEmergencyData private _emergencyData;

    // Use constants from Constants.sol
    using Constants for address;

    // Uniswap router addresses - Using V2 only
    address private constant UNISWAP_V2_ROUTER = Constants.UNISWAP_V2_ROUTER;

    // Arbitrage tracking. Reputation is a score used for the incentive bonus —
    // NOT a claimable balance (the contract never owes these amounts).
    IRepegManager.ArbitrageOpportunity[] private _arbitrageOpportunities;
    mapping(address => uint256) private _arbitrageurReputation;

    // Effective incentive cap, adjustable up to MAX_INCENTIVE
    uint128 private _maxIncentive = uint128(MAX_INCENTIVE);

    // Optimized repeg history (circular buffer for gas efficiency)
    PackedPriceHistory[50] private _priceHistory;
    uint8 private _historyIndex;

    // Price cache for gas optimization
    uint128 private _cachedPrice;
    uint64 private _cacheTimestamp;
    uint64 private constant CACHE_DURATION = 60; // 1 minute cache

    // ============ SECURITY ENHANCEMENTS ============

    // Circuit breaker for external calls
    struct CircuitBreakerState {
        uint64 failureCount;
        uint64 lastFailureTime;
        uint64 lastSuccessTime;
        bool isTripped;
    }

    CircuitBreakerState private _circuitBreaker;

    // Gas limits for critical operations
    uint256 private constant MAX_EXTERNAL_CALL_GAS = 100000;
    uint256 private constant MAX_SWAP_GAS = 200000;

    // Circuit breaker thresholds
    uint256 private constant FAILURE_THRESHOLD = 3;
    uint256 private constant RECOVERY_TIME = 1 hours;

    // ============ MODIFIERS ============
    modifier onlyStableGuard() {
        if (msg.sender != STABLE_GUARD) revert Unauthorized();
        _;
    }

    modifier onlyAuthorized() {
        if (msg.sender != owner() && msg.sender != STABLE_GUARD) revert Unauthorized();
        _;
    }

    modifier notPaused() {
        if (_emergencyData.emergencyPaused) revert EmergencyPaused();
        _;
    }

    modifier validAddress(address addr) {
        assembly {
            if iszero(addr) {
                mstore(0x00, 0x7c946ed7) // "InvalidAddress()"
                revert(0x1c, 0x04)
            }
        }
        _;
    }

    modifier circuitBreakerCheck() {
        require(!_circuitBreaker.isTripped, "Circuit breaker tripped");
        _;
    }

    // ============ SECURITY FUNCTIONS ============

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

        return (success, result);
    }

    // ============ CONSTRUCTOR ============
    constructor(
        address _stableGuard,
        address _priceOracle,
        address _stableToken,
        address _arbitrageManager,
        IRepegManager.RepegConfig memory _initialConfig
    )
        Ownable(msg.sender)
        validAddress(_stableGuard)
        validAddress(_priceOracle)
        validAddress(_stableToken)
        validAddress(_arbitrageManager)
    {
        // Assembly optimized validation
        assembly {
            if or(or(iszero(_stableGuard), iszero(_priceOracle)), or(iszero(_stableToken), iszero(_arbitrageManager))) {
                mstore(0x00, 0x7c946ed7) // "Invalid address"
                revert(0x1c, 0x04)
            }
        }

        STABLE_GUARD = _stableGuard;
        PRICE_ORACLE = IPriceOracle(_priceOracle);
        STABLE_TOKEN = IERC20(_stableToken);
        ARBITRAGE_MANAGER = IArbitrageManager(_arbitrageManager);

        // Validate and set initial configuration
        _validateRepegConfig(_initialConfig);
        _config = _initialConfig;

        // Initialize state
        _state = IRepegManager.RepegState({
            currentPrice: _initialConfig.targetPrice,
            lastRepegTime: uint64(block.timestamp),
            dailyRepegCount: 0,
            lastResetDay: uint32(block.timestamp / SECONDS_PER_DAY),
            consecutiveRepegs: 0,
            repegDirection: 0,
            inProgress: false
        });

        // Initialize packed emergency data
        _emergencyData =
            PackedEmergencyData({emergencyPaused: false, priceBuffer: 0, lastEmergencyTime: 0, historyIndex: 0});
    }

    // ============ CORE REPEG FUNCTIONS ============

    /// @inheritdoc IRepegManager
    /// @dev Only callable through StableGuard, which passes the end user as the
    ///      beneficiary so the incentive reaches the actual caller.
    function checkAndTriggerRepeg(address beneficiary)
        external
        override
        onlyStableGuard
        notPaused
        nonReentrant
        circuitBreakerCheck
        returns (bool triggered, uint128 newPrice)
    {
        require(_config.enabled, "Repeg disabled");
        if (beneficiary == address(0)) revert InvalidAddress();

        // Update daily counter if needed
        _updateDailyCounter();

        // Check if repeg is needed
        (bool needed,) = isRepegNeeded();
        if (!needed) {
            return (false, _state.currentPrice);
        }

        // Check cooldown and daily limits
        if (!_canExecuteRepeg()) {
            return (false, _state.currentPrice);
        }

        // Calculate repeg parameters
        (uint128 targetPrice, uint8 direction, uint128 incentive) = calculateRepegParameters();

        // Apply arbitrageur bonus if applicable
        if (incentive > 0 && _arbitrageurReputation[beneficiary] > 0) {
            incentive = uint128((incentive * 110) / 100); // 10% bonus
        }

        // Capture current market price before repeg for event logging
        uint128 priceBeforeRepeg = _getCurrentMarketPriceCached();

        // Execute repeg
        bool success = _executeRepegInternal(targetPrice, direction);
        if (success) {
            // Pay incentive to the beneficiary (pays only if the SGD pool covers it)
            _payIncentive(beneficiary, incentive);

            triggered = true;
            newPrice = targetPrice;

            emit RepegEvent(0, priceBeforeRepeg, targetPrice, beneficiary, incentive, uint32(block.timestamp));
        }

        return (triggered, newPrice);
    }

    /// @inheritdoc IRepegManager
    function executeRepeg(uint128 targetPrice, uint8 direction)
        external
        override
        onlyAuthorized
        notPaused
        nonReentrant
        returns (bool success)
    {
        // Validate parameters
        if (targetPrice == 0 || direction > 2) revert InvalidParameters();

        return _executeRepegInternal(targetPrice, direction);
    }

    /// @inheritdoc IRepegManager
    function calculateRepegParameters()
        public
        override
        returns (uint128 targetPrice, uint8 direction, uint128 incentive)
    {
        uint128 currentPrice = _getCurrentMarketPriceCached();
        targetPrice = _config.targetPrice;

        // Determine direction
        if (currentPrice > targetPrice) {
            direction = 2; // Down
        } else if (currentPrice < targetPrice) {
            direction = 1; // Up
        } else {
            direction = 0; // No repeg needed
        }

        // Calculate incentive based on deviation
        if (direction != 0) {
            uint128 deviation;
            if (currentPrice > targetPrice) {
                deviation = uint128(((currentPrice - targetPrice) * Constants.BASIS_POINTS) / targetPrice);
            } else {
                deviation = uint128(((targetPrice - currentPrice) * Constants.BASIS_POINTS) / targetPrice);
            }

            // incentive = (deviation * incentiveRate * totalLiquidity) / (BASIS_POINTS * BASIS_POINTS)
            incentive = uint128(
                (deviation * _config.incentiveRate * _totalLiquidityView())
                    / (Constants.BASIS_POINTS * Constants.BASIS_POINTS)
            );

            // Cap incentive at the configured maximum
            if (incentive > _maxIncentive) {
                incentive = _maxIncentive;
            }
        }
    }

    // ============ GAS OPTIMIZED HELPER FUNCTIONS ============

    /**
     * @dev Get current market price with caching for gas optimization
     */
    function _getCurrentMarketPriceCached() internal returns (uint128) {
        // Check if cache is still valid
        if (block.timestamp - _cacheTimestamp < CACHE_DURATION) {
            return _cachedPrice;
        }

        // Cache expired, get fresh price and update cache
        uint128 freshPrice = _getCurrentMarketPrice();
        _updatePriceCache(freshPrice);
        return freshPrice;
    }

    /**
     * @dev Update price cache
     */
    function _updatePriceCache(uint128 newPrice) internal {
        _cachedPrice = newPrice;
        _cacheTimestamp = uint64(block.timestamp);
    }

    // ============ LIQUIDITY MANAGEMENT ============

    /// @inheritdoc IRepegManager
    /// @dev ETH (msg.value) and SGD deposits are tracked in separate pools so
    ///      each provider is repaid in the asset they deposited.
    function provideLiquidity(uint256 amount) external payable override nonReentrant returns (bool success) {
        if (amount == 0) revert InvalidParameters();

        if (msg.value > 0) {
            if (msg.value != amount) revert InvalidParameters();
            _ethLiquidity[msg.sender] += amount;
            _totalEthLiquidity += amount;
        } else {
            bool transferSuccess = STABLE_TOKEN.transferFrom(msg.sender, address(this), amount);
            if (!transferSuccess) revert TransferFailed();
            _sgdLiquidity[msg.sender] += amount;
            _totalSgdLiquidity += amount;
        }

        return true;
    }

    /// @inheritdoc IRepegManager
    /// @dev Withdraws from the caller's SGD pool; use withdrawEthLiquidity for ETH
    function withdrawLiquidity(uint256 amount) external override nonReentrant returns (bool success) {
        if (amount == 0) revert InvalidParameters();
        if (_sgdLiquidity[msg.sender] < amount) revert InsufficientLiquidity();
        if (_totalSgdLiquidity < amount || _totalLiquidityView() - _reservedLiquidity < amount) {
            revert InsufficientLiquidity();
        }

        // Update state
        _sgdLiquidity[msg.sender] -= amount;
        _totalSgdLiquidity -= amount;

        // Transfer funds
        bool transferSuccess = STABLE_TOKEN.transfer(msg.sender, amount);
        if (!transferSuccess) revert TransferFailed();

        return true;
    }

    /// @inheritdoc IRepegManager
    function withdrawEthLiquidity(uint256 amount) external override nonReentrant returns (bool success) {
        if (amount == 0) revert InvalidParameters();
        if (_ethLiquidity[msg.sender] < amount) revert InsufficientLiquidity();
        if (_totalEthLiquidity < amount || address(this).balance < amount) revert InsufficientLiquidity();

        // Update state
        _ethLiquidity[msg.sender] -= amount;
        _totalEthLiquidity -= amount;

        // Transfer funds
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        return true;
    }

    // ============ ARBITRAGE FUNCTIONS ============

    /// @inheritdoc IRepegManager
    function executeArbitrage(uint256 amount, uint128 maxSlippage)
        external
        payable
        override
        notPaused
        nonReentrant
        returns (uint128 profit)
    {
        if (amount == 0 || maxSlippage > Constants.REPEG_DEVIATION_THRESHOLD * 2) {
            revert InvalidParameters(); // Max 10% slippage
        }

        // Get current price before arbitrage (use cached version)
        uint128 priceBefore = _getCurrentMarketPriceCached();

        // Check if arbitrage opportunity exists
        IRepegManager.ArbitrageOpportunity[] memory opportunities = this.getArbitrageOpportunities();
        if (opportunities.length == 0) {
            return 0;
        }

        // Execute arbitrage through ArbitrageManager
        // Transfer funds to ArbitrageManager for execution
        if (msg.value > 0) {
            (bool success,) = address(ARBITRAGE_MANAGER).call{value: msg.value}("");
            require(success, "ETH transfer failed");
        }

        // Trigger arbitrage execution
        try ARBITRAGE_MANAGER.executeArbitrage() {
            // Calculate profit based on price improvement
            uint128 priceAfter = _getCurrentMarketPrice();

            // Update price cache with new price
            _updatePriceCache(priceAfter);

            // Calculate actual profit from price movement towards target
            if (priceAfter != priceBefore) {
                uint128 targetPrice = _config.targetPrice;

                // Gas optimized profit calculation using assembly
                assembly {
                    let deviationBefore
                    let deviationAfter

                    if gt(priceBefore, targetPrice) { deviationBefore := sub(priceBefore, targetPrice) }
                    if lt(priceBefore, targetPrice) { deviationBefore := sub(targetPrice, priceBefore) }

                    if gt(priceAfter, targetPrice) { deviationAfter := sub(priceAfter, targetPrice) }
                    if lt(priceAfter, targetPrice) { deviationAfter := sub(targetPrice, priceAfter) }

                    // Profit is proportional to deviation reduction
                    if lt(deviationAfter, deviationBefore) {
                        let improvement := sub(deviationBefore, deviationAfter)
                        profit := div(mul(improvement, amount), 1000000000000000000) // PRICE_PRECISION (1e18)
                    }
                }

                if (profit > 0) {
                    // Update price state
                    _state.currentPrice = priceAfter;

                    // Reputation score only — never a claimable balance
                    _arbitrageurReputation[msg.sender] += profit;

                    emit RepegArbitrageExecuted(block.timestamp);
                }
            }
        } catch {
            revert ArbitrageWindowExpired();
        }

        return profit;
    }

    // ============ CONFIGURATION FUNCTIONS ============

    /// @inheritdoc IRepegManager
    function updateRepegConfig(IRepegManager.RepegConfig calldata newConfig) external override onlyOwner {
        _validateRepegConfig(newConfig);
        _config = newConfig;
    }

    /// @inheritdoc IRepegManager
    function setEmergencyPause(bool paused) external override onlyOwner {
        _emergencyData.emergencyPaused = paused;
        _emergencyData.lastEmergencyTime = uint64(block.timestamp);
    }

    /// @inheritdoc IRepegManager
    function updateDeviationThreshold(uint64 newThreshold) external override onlyOwner {
        if (newThreshold == 0 || newThreshold > MAX_DEVIATION) revert InvalidThreshold();
        _config.deviationThreshold = newThreshold;
    }

    /// @inheritdoc IRepegManager
    function updateIncentiveParameters(uint16 rate, uint128 maxIncentive) external override onlyOwner {
        if (rate > 1000 || maxIncentive == 0 || maxIncentive > MAX_INCENTIVE) revert InvalidParameters(); // Max 10% rate
        _config.incentiveRate = rate;
        _maxIncentive = maxIncentive;
    }

    // ============ VIEW FUNCTIONS ============

    /// @inheritdoc IRepegManager
    function getRepegConfig() external view override returns (IRepegManager.RepegConfig memory) {
        return _config;
    }

    /// @inheritdoc IRepegManager
    function getRepegState() external view override returns (IRepegManager.RepegState memory) {
        return _state;
    }

    /// @inheritdoc IRepegManager
    function isRepegNeeded() public override returns (bool needed, uint128 currentDeviation) {
        uint128 currentPrice = _getCurrentMarketPriceCached();
        uint128 targetPrice = _config.targetPrice;

        // Return false for invalid prices
        if (currentPrice == 0 || targetPrice == 0) {
            return (false, 0);
        }

        if (currentPrice == targetPrice) {
            return (false, 0);
        }

        // Safe calculation to prevent overflow with extreme prices
        uint256 priceDiff =
            currentPrice > targetPrice ? uint256(currentPrice - targetPrice) : uint256(targetPrice - currentPrice);

        // For extreme price differences, set maximum deviation
        // Check if priceDiff is more than 100x the target price
        // Use a safer comparison to avoid potential division issues
        if (priceDiff >= uint256(targetPrice) * 100) {
            currentDeviation = type(uint128).max;
        } else {
            // Safe calculation with overflow protection
            if (priceDiff > type(uint256).max / Constants.BASIS_POINTS) {
                currentDeviation = type(uint128).max;
            } else {
                uint256 deviationCalc = (priceDiff * Constants.BASIS_POINTS) / targetPrice;
                currentDeviation = deviationCalc > type(uint128).max ? type(uint128).max : uint128(deviationCalc);
            }
        }

        needed = currentDeviation >= _config.deviationThreshold;
    }

    /// @inheritdoc IRepegManager
    function getCurrentDeviation() external override returns (uint128 deviation, bool isAbove) {
        uint128 currentPrice = _getCurrentMarketPriceCached();
        uint128 targetPrice = _config.targetPrice;

        if (currentPrice > targetPrice) {
            uint256 priceDiff = uint256(currentPrice - targetPrice);
            uint256 deviationCalc = (priceDiff * Constants.BASIS_POINTS) / targetPrice;
            deviation = deviationCalc > type(uint128).max ? type(uint128).max : uint128(deviationCalc);
            isAbove = true;
        } else {
            uint256 priceDiff = uint256(targetPrice - currentPrice);
            uint256 deviationCalc = (priceDiff * Constants.BASIS_POINTS) / targetPrice;
            deviation = deviationCalc > type(uint128).max ? type(uint128).max : uint128(deviationCalc);
            isAbove = false;
        }
    }

    /// @inheritdoc IRepegManager
    function getArbitrageOpportunities() external override returns (IRepegManager.ArbitrageOpportunity[] memory) {
        // Generate simplified opportunities based on current price deviation
        uint128 currentPrice = _getCurrentMarketPriceCached();
        uint128 targetPrice = _config.targetPrice;

        if (currentPrice == 0 || targetPrice == 0) {
            return new IRepegManager.ArbitrageOpportunity[](0);
        }

        // Calculate price deviation safely
        uint256 priceDiff =
            currentPrice > targetPrice ? uint256(currentPrice - targetPrice) : uint256(targetPrice - currentPrice);
        uint256 deviationCalc = (priceDiff * Constants.BASIS_POINTS) / targetPrice;
        uint128 deviation = deviationCalc > type(uint128).max ? type(uint128).max : uint128(deviationCalc);

        // Only generate opportunities if deviation is significant (> 0.5%)
        if (deviation < 50) {
            return new IRepegManager.ArbitrageOpportunity[](0);
        }

        // Return single opportunity based on current market conditions
        IRepegManager.ArbitrageOpportunity[] memory opportunities = new IRepegManager.ArbitrageOpportunity[](1);
        opportunities[0] = IRepegManager.ArbitrageOpportunity({
            tokenA: address(STABLE_TOKEN),
            tokenB: Constants.WETH,
            amountIn: 1000 * Constants.PRICE_PRECISION, // 1000 tokens
            expectedProfit: (deviation * 1000 * Constants.PRICE_PRECISION) / (2 * Constants.BASIS_POINTS), // Half of deviation as profit
            confidence: 8000, // 80% confidence
            expiryTime: uint64(block.timestamp + 300) // 5 minutes expiry
        });

        return opportunities;
    }

    /// @inheritdoc IRepegManager
    function calculateIncentive(address caller) external override returns (uint128 incentive) {
        (, uint128 deviation) = isRepegNeeded();
        if (deviation == 0) return 0;

        incentive = uint128(
            (deviation * _config.incentiveRate * _totalLiquidityView())
                / (Constants.BASIS_POINTS * Constants.BASIS_POINTS)
        );
        if (incentive > _maxIncentive) {
            incentive = _maxIncentive;
        }

        // Bonus for frequent arbitrageurs
        if (_arbitrageurReputation[caller] > 0) {
            incentive = uint128((incentive * 110) / 100); // 10% bonus
        }
    }

    /// @inheritdoc IRepegManager
    function getLiquidityPoolStatus()
        external
        view
        override
        returns (uint256 totalLiquidity, uint256 availableLiquidity)
    {
        totalLiquidity = _totalLiquidityView();
        availableLiquidity = totalLiquidity - _reservedLiquidity;
    }

    /// @inheritdoc IRepegManager
    function getRepegHistory(uint256 count)
        external
        view
        override
        returns (uint128[] memory prices, uint64[] memory timestamps)
    {
        if (count > 50) count = 50;

        prices = new uint128[](count);
        timestamps = new uint64[](count);

        for (uint256 i = 0; i < count; i++) {
            uint8 index = (_historyIndex + 50 - uint8(count) + uint8(i)) % 50;
            prices[i] = _priceHistory[index].price;
            timestamps[i] = _priceHistory[index].timestamp;
        }
    }

    /// @inheritdoc IRepegManager
    function canTriggerRepeg() external override returns (bool canTrigger, string memory reason) {
        if (_emergencyData.emergencyPaused) {
            return (false, "Emergency paused");
        }

        if (_state.inProgress) {
            return (false, "Repeg in progress");
        }

        if (!_canExecuteRepeg()) {
            return (false, "Cooldown or daily limit");
        }

        (bool needed,) = isRepegNeeded();
        if (!needed) {
            return (false, "Repeg not needed");
        }

        if (_totalLiquidityView() < MIN_LIQUIDITY) {
            return (false, "Insufficient liquidity");
        }

        return (true, "");
    }

    /// @inheritdoc IRepegManager
    function getOptimalRepegTiming() external override returns (uint64 nextOptimalTime, uint32 confidence) {
        // Simple heuristic based on historical patterns
        uint64 avgInterval = _calculateAverageRepegInterval();
        nextOptimalTime = _state.lastRepegTime + avgInterval;

        // Confidence based on price stability and liquidity
        uint128 currentDeviation = _getCurrentDeviation();
        uint256 liquidityRatio = (_totalLiquidityView() * 100) / MIN_LIQUIDITY;

        confidence = uint32((10000 - currentDeviation) * liquidityRatio / 100);
        if (confidence > 10000) confidence = 10000;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _executeRepegInternal(uint128 targetPrice, uint8 direction) internal returns (bool success) {
        if (_state.inProgress) revert RepegInProgress();

        // Set repeg in progress
        _state.inProgress = true;

        try this._performRepegOperations(targetPrice, direction) {
            // Update state on success
            _updateRepegState(targetPrice, direction);
            _addToHistory(targetPrice);

            emit RepegEvent(1, _state.currentPrice, targetPrice, msg.sender, 0, uint32(block.timestamp));
            success = true;
        } catch {
            emit RepegEvent(2, _state.currentPrice, targetPrice, msg.sender, 0, uint32(block.timestamp));
            success = false;
        }

        // Clear progress flag
        _state.inProgress = false;

        return success;
    }

    function _performRepegOperations(uint128 targetPrice, uint8 direction) external {
        require(msg.sender == address(this), "Internal only");

        // Get current market conditions
        uint128 currentPrice = _getCurrentMarketPrice();
        uint128 deviation = _getCurrentDeviation();

        // Calculate required intervention amount based on deviation
        uint256 interventionAmount = _calculateInterventionAmount(deviation, direction);

        if (interventionAmount == 0) {
            revert("No intervention needed");
        }

        // Store pre-intervention state for effectiveness analysis
        uint128 preInterventionPrice = currentPrice;

        // Execute arbitrage opportunities first to improve price discovery
        _executeArbitrageIfProfitable();

        // Execute the appropriate repeg strategy based on direction
        if (direction == 1) {
            // Price is below target - need to buy stable token (increase demand)
            _executeBuyPressure(targetPrice, interventionAmount);
        } else if (direction == 2) {
            // Price is above target - need to sell stable token (increase supply)
            _executeSellPressure(targetPrice, interventionAmount);
        } else {
            revert("Invalid direction");
        }

        // Analyze intervention effectiveness and adapt
        _analyzeInterventionEffectiveness(preInterventionPrice, targetPrice, interventionAmount, direction);

        // Update liquidity reserves after operation
        _updateLiquidityReserves(interventionAmount, direction);

        // Emit detailed repeg operation event
        emit RepegOperationExecuted(
            targetPrice,
            currentPrice,
            interventionAmount,
            direction == 1 ? "Buy Pressure" : "Sell Pressure",
            block.timestamp
        );
    }

    function _analyzeInterventionEffectiveness(
        uint128 prePrice,
        uint128 targetPrice,
        uint256 interventionAmount,
        uint8 direction
    ) internal {
        // Simulate post-intervention price (in real implementation, this would be measured)
        uint128 postPrice = _simulatePostInterventionPrice(prePrice, targetPrice, interventionAmount, direction);

        // Calculate effectiveness metrics
        uint128 preDeviation = prePrice > targetPrice
            ? uint128(((prePrice - targetPrice) * Constants.BASIS_POINTS) / targetPrice)
            : uint128(((targetPrice - prePrice) * Constants.BASIS_POINTS) / targetPrice);

        uint128 postDeviation = postPrice > targetPrice
            ? uint128(((postPrice - targetPrice) * Constants.BASIS_POINTS) / targetPrice)
            : uint128(((targetPrice - postPrice) * Constants.BASIS_POINTS) / targetPrice);

        // Adaptive learning: adjust future intervention parameters based on effectiveness
        if (postDeviation < preDeviation / 2) {
            // Very effective - intervention was successful
            _adaptInterventionStrategy(true, preDeviation, postDeviation);
        } else if (postDeviation >= preDeviation) {
            // Ineffective or counterproductive
            _adaptInterventionStrategy(false, preDeviation, postDeviation);
        }
        // Moderate effectiveness requires no immediate adaptation
    }

    function _simulatePostInterventionPrice(
        uint128 prePrice,
        uint128, /* targetPrice */
        uint256 interventionAmount,
        uint8 direction
    )
        internal
        pure
        returns (uint128)
    {
        // Simulate market response to intervention
        uint256 priceImpact = (interventionAmount * 50) / (10000 * Constants.PRICE_PRECISION); // 0.5% impact per 10k intervention

        // Direction convention (shared across the contract): 1 = buy SGD (price
        // below target, intervention pushes it UP), 2 = sell SGD (pushes it DOWN).
        if (direction == 1) {
            return uint128(prePrice + (prePrice * priceImpact) / Constants.BASIS_POINTS);
        } else {
            return uint128(prePrice - (prePrice * priceImpact) / Constants.BASIS_POINTS);
        }
    }

    function _adaptInterventionStrategy(
        bool wasEffective,
        uint128,
        /* preDeviation */
        uint128 postDeviation
    )
        internal
    {
        // Adaptive parameter adjustment (simplified for testnet)
        if (wasEffective) {
            // Successful intervention - maintain or slightly reduce aggressiveness
            if (_config.deviationThreshold > Constants.MIN_ARBITRAGE_PROFIT) {
                // Don't go below 0.5%
                _config.deviationThreshold = (_config.deviationThreshold * 95) / 100; // Reduce by 5%
            }
        } else {
            // Ineffective intervention - increase threshold to be more selective
            if (_config.deviationThreshold < Constants.MAX_ARBITRAGE_SLIPPAGE) {
                // Don't go above 3%
                _config.deviationThreshold = (_config.deviationThreshold * 110) / 100; // Increase by 10%
            }
        }

        // Reset consecutive repegs if intervention was effective
        if (wasEffective && postDeviation < Constants.MIN_ARBITRAGE_PROFIT) {
            // Less than 0.5% deviation
            _state.consecutiveRepegs = 0;
        }
    }

    function _getCurrentMarketPrice() internal returns (uint128) {
        // Use PriceOracle with Chainlink feeds for accurate pricing
        try PRICE_ORACLE.getTokenPrice(address(STABLE_TOKEN)) returns (uint256 price) {
            return uint128(price);
        } catch {
            // Fallback to last known price if oracle fails
            return _state.currentPrice;
        }
    }

    /**
     * @dev Execute arbitrage if profitable opportunities exist
     */
    function _executeArbitrageIfProfitable() internal {
        try ARBITRAGE_MANAGER.executeArbitrage() {
            // Arbitrage executed successfully
            emit RepegArbitrageExecuted(block.timestamp);
        } catch {
            // Arbitrage failed or no profitable opportunities
            // Continue with normal repeg operations
        }
    }

    // ============ EVENTS ============
    // Events are defined in IRepegManager interface
    event BuyPressureExecuted(uint256 amountIn, uint256 tokensReceived, uint128 newPrice);
    event SellPressureExecuted(uint256 amountIn, uint256 ethReceived, uint128 newPrice);

    function _calculateMarketVolatility() internal view returns (uint128) {
        // Simulate market volatility based on time and recent activity
        uint256 timeFactor = block.timestamp % 3600; // Hourly cycle
        uint256 activityFactor = _state.consecutiveRepegs * 50; // More activity = more volatility

        // Create pseudo-random volatility between 99.5% and 100.5%
        uint256 volatility = 9950 + (timeFactor % 100) + (activityFactor % 50);

        // Ensure volatility stays within reasonable bounds
        if (volatility < 9900) volatility = 9900; // Min 99%
        if (volatility > 10100) volatility = 10100; // Max 101%

        return uint128(volatility);
    }

    function _getCurrentDeviation() internal returns (uint128) {
        uint128 currentPrice = _getCurrentMarketPriceCached();
        uint128 targetPrice = _config.targetPrice;

        if (currentPrice == targetPrice) return 0;

        return currentPrice > targetPrice
            ? uint128(((currentPrice - targetPrice) * Constants.BASIS_POINTS) / targetPrice)
            : uint128(((targetPrice - currentPrice) * Constants.BASIS_POINTS) / targetPrice);
    }

    function _shouldTriggerRepeg(uint128 currentPrice, uint128 targetPrice) internal view returns (bool) {
        uint128 deviation = currentPrice > targetPrice ? currentPrice - targetPrice : targetPrice - currentPrice;

        uint128 deviationBps = uint128((deviation * Constants.BASIS_POINTS) / targetPrice);

        // Adaptive threshold based on market conditions
        uint128 adaptiveThreshold = _calculateAdaptiveThreshold();

        return deviationBps >= adaptiveThreshold;
    }

    function _calculateAdaptiveThreshold() internal view returns (uint128) {
        uint128 baseThreshold = _config.deviationThreshold;

        // Increase threshold during high volatility to prevent excessive interventions
        uint128 volatility = _calculateMarketVolatility();
        if (volatility > 10100 || volatility < 9900) {
            // High volatility (>1%)
            baseThreshold = (baseThreshold * 150) / 100; // Increase by 50%
        } else if (volatility > 10050 || volatility < 9950) {
            // Medium volatility (>0.5%)
            baseThreshold = (baseThreshold * 125) / 100; // Increase by 25%
        }

        // Decrease threshold if consecutive repegs are low (stable period)
        if (_state.consecutiveRepegs == 0 && block.timestamp - _state.lastRepegTime > 86400) {
            // 24 hours
            baseThreshold = (baseThreshold * 80) / 100; // Decrease by 20%
        }

        // Liquidity-based adjustment
        if (_totalLiquidityView() < 5000 * Constants.PRICE_PRECISION) {
            // Low liquidity
            baseThreshold = (baseThreshold * 75) / 100; // More sensitive (decrease by 25%)
        } else if (_totalLiquidityView() > 50000 * Constants.PRICE_PRECISION) {
            // High liquidity
            baseThreshold = (baseThreshold * 110) / 100; // Less sensitive (increase by 10%)
        }

        // Ensure minimum and maximum bounds
        uint128 minThreshold = 25; // 0.25%
        uint128 maxThreshold = 500; // 5%

        if (baseThreshold < minThreshold) return minThreshold;
        if (baseThreshold > maxThreshold) return maxThreshold;

        return baseThreshold;
    }

    function _canExecuteRepeg() internal view returns (bool) {
        // Check cooldown
        if (block.timestamp < _state.lastRepegTime + _config.repegCooldown) {
            return false;
        }

        // Check daily limit
        if (_state.dailyRepegCount >= _config.maxRepegPerDay) {
            return false;
        }

        return true;
    }

    function _updateDailyCounter() internal {
        uint32 currentDay = uint32(block.timestamp / SECONDS_PER_DAY);
        if (currentDay > _state.lastResetDay) {
            _state.dailyRepegCount = 0;
            _state.lastResetDay = currentDay;
        }
    }

    function _updateRepegState(uint128 newPrice, uint8 direction) internal {
        _state.currentPrice = newPrice;
        _state.lastRepegTime = uint64(block.timestamp);
        _state.dailyRepegCount++;

        if (_state.repegDirection == direction) {
            _state.consecutiveRepegs++;
        } else {
            _state.consecutiveRepegs = 1;
            _state.repegDirection = direction;
        }
    }

    function _addToHistory(uint128 price) internal {
        _priceHistory[_historyIndex] =
            PackedPriceHistory({price: price, timestamp: uint64(block.timestamp), reserved: 0});
        _historyIndex = (_historyIndex + 1) % 50;
    }

    /// @dev Combined liquidity across both pools (nominal units)
    function _totalLiquidityView() internal view returns (uint256) {
        return _totalEthLiquidity + _totalSgdLiquidity;
    }

    function _payIncentive(address recipient, uint128 amount) internal {
        // Incentives are paid in SGD, so they must be covered by the SGD pool
        if (amount > 0 && _totalSgdLiquidity >= amount) {
            _reservedLiquidity += amount;
            bool success = STABLE_TOKEN.transfer(recipient, amount);
            if (success) {
                _totalSgdLiquidity -= amount;
            }
            _reservedLiquidity -= amount;
        }
    }

    function _validateRepegConfig(IRepegManager.RepegConfig memory config) internal pure {
        if (config.targetPrice == 0) revert InvalidParameters();
        if (config.deviationThreshold == 0 || config.deviationThreshold > MAX_DEVIATION) revert InvalidThreshold();
        if (config.repegCooldown == 0 || config.repegCooldown > Constants.REPEG_COOLDOWN * 24) {
            revert InvalidParameters();
        } // Max 1 day
        if (config.arbitrageWindow == 0 || config.arbitrageWindow > Constants.REPEG_ARBITRAGE_WINDOW * 2) {
            revert InvalidParameters();
        } // Max 1 hour
        if (config.incentiveRate > Constants.REPEG_INCENTIVE_RATE * 10) revert InvalidParameters(); // Max 10%
        if (config.maxRepegPerDay == 0 || config.maxRepegPerDay > Constants.MAX_REPEG_PER_DAY * 10) {
            revert InvalidParameters();
        }
    }

    function _calculateAverageRepegInterval() internal view returns (uint64) {
        uint64 totalInterval = 0;
        uint256 count = 0;

        for (uint256 i = 1; i < 50; i++) {
            if (_priceHistory[i].timestamp > 0 && _priceHistory[i - 1].timestamp > 0) {
                totalInterval += _priceHistory[i].timestamp - _priceHistory[i - 1].timestamp;
                count++;
            }
        }

        return count > 0 ? totalInterval / uint64(count) : 3600; // Default 1 hour
    }

    // ============ REPEG OPERATION FUNCTIONS ============

    function _calculateInterventionAmount(
        uint128 deviation,
        uint8 /* direction */
    )
        internal
        view
        returns (uint256)
    {
        // Advanced PID-like controller for price stabilization

        // Proportional component - immediate response to current deviation
        uint256 proportional = (_totalLiquidityView() * deviation) / (Constants.BASIS_POINTS * 8);

        // Integral component - accumulated error over time (consecutive repegs)
        uint256 integral = (proportional * _state.consecutiveRepegs * 300) / Constants.BASIS_POINTS; // 3% per consecutive repeg

        // Derivative component - rate of change (based on time since last repeg)
        uint256 timeSinceLastRepeg = block.timestamp - _state.lastRepegTime;
        uint256 derivative = 0;

        if (timeSinceLastRepeg < 3600) {
            // If less than 1 hour, increase urgency
            derivative = (proportional * (3600 - timeSinceLastRepeg)) / 3600;
        }

        // Combine PID components
        uint256 pidAmount = proportional + (integral / 10) + (derivative / 5);

        // Apply volatility dampening - reduce intervention during high volatility
        uint128 volatility = _calculateMarketVolatility();
        if (volatility > 10050 || volatility < 9950) {
            // High volatility
            pidAmount = (pidAmount * 7) / 10; // Reduce by 30%
        }

        // Dynamic maximum based on market conditions
        uint256 maxIntervention = _calculateDynamicMaxIntervention(deviation);

        return pidAmount > maxIntervention ? maxIntervention : pidAmount;
    }

    function _calculateDynamicMaxIntervention(uint128 deviation) internal view returns (uint256) {
        // Base maximum: 10% of total liquidity
        uint256 baseMax = _totalLiquidityView() / 10;

        // Increase maximum for larger deviations (emergency situations)
        if (deviation > 500) {
            // > 5% deviation
            baseMax = (_totalLiquidityView() * 15) / 100; // 15% max
        } else if (deviation > 200) {
            // > 2% deviation
            baseMax = (_totalLiquidityView() * 12) / 100; // 12% max
        }

        // Reduce maximum if liquidity is low
        if (_totalLiquidityView() < 10000 * Constants.PRICE_PRECISION) {
            baseMax = baseMax / 2; // Conservative approach with low liquidity
        }

        return baseMax;
    }

    function _executeBuyPressure(
        uint128,
        /* targetPrice */
        uint256 amount
    )
        internal
    {
        // Real buy pressure using Uniswap V2: spends ETH liquidity, receives SGD
        if (amount > 0 && _totalEthLiquidity >= amount && address(this).balance >= amount) {
            // Get quote from Uniswap V2 for pricing
            uint256 expectedTokens = _getUniswapV2Quote(Constants.WETH, address(STABLE_TOKEN), amount);

            // Create path for swap
            address[] memory path = new address[](2);
            path[0] = Constants.WETH;
            path[1] = address(STABLE_TOKEN);

            // Execute swap on Uniswap V2 with slippage protection
            bytes memory swapData = abi.encodeWithSignature(
                "swapExactEthForTokens(uint256,address[],address,uint256)",
                (expectedTokens * 97) / 100, // amountOutMin (3% slippage)
                path, // path
                address(this), // to
                block.timestamp + 300 // deadline
            );

            // Execute the swap using safe external call
            (bool success, bytes memory result) =
                _safeExternalCallWithValue(UNISWAP_V2_ROUTER, swapData, amount, MAX_SWAP_GAS);
            if (success) {
                uint256[] memory amounts = abi.decode(result, (uint256[]));
                uint256 tokensReceived = amounts[amounts.length - 1];

                // ETH spent, SGD received
                _totalEthLiquidity -= amount;
                _totalSgdLiquidity += tokensReceived;
                _state.currentPrice = _getCurrentMarketPrice();

                emit BuyPressureExecuted(amount, tokensReceived, _state.currentPrice);
            }
        }
    }

    function _executeSellPressure(
        uint128,
        /* targetPrice */
        uint256 amount
    )
        internal
    {
        uint256 stableBalance = STABLE_TOKEN.balanceOf(address(this));

        if (amount > 0 && stableBalance >= amount) {
            // First approve the router to spend our tokens
            STABLE_TOKEN.approve(UNISWAP_V2_ROUTER, amount);

            // Get quote from Uniswap V2
            uint256 expectedEth = _getUniswapV2Quote(address(STABLE_TOKEN), Constants.WETH, amount);

            // Create path for swap
            address[] memory path = new address[](2);
            path[0] = address(STABLE_TOKEN);
            path[1] = Constants.WETH;

            // Execute swap on Uniswap V2 using low-level calls
            bytes memory swapData = abi.encodeWithSignature(
                "swapExactTokensForEth(uint256,uint256,address[],address,uint256)",
                amount, // amountIn
                (expectedEth * 97) / 100, // amountOutMin (3% slippage)
                path, // path
                address(this), // to
                block.timestamp + 300 // deadline
            );

            // Execute the swap using safe external call
            (bool success, bytes memory result) = _safeExternalCall(UNISWAP_V2_ROUTER, swapData, MAX_SWAP_GAS);
            if (success) {
                uint256[] memory amounts = abi.decode(result, (uint256[]));
                uint256 ethReceived = amounts[amounts.length - 1];

                // SGD spent, ETH received
                _totalSgdLiquidity = _totalSgdLiquidity >= amount ? _totalSgdLiquidity - amount : 0;
                _totalEthLiquidity += ethReceived;
                _state.currentPrice = _getCurrentMarketPrice();

                emit SellPressureExecuted(amount, ethReceived, _state.currentPrice);
            }
        }
    }

    function _getUniswapV2Quote(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Use low-level call for getAmountsOut
        bytes memory getAmountsData = abi.encodeWithSignature("getAmountsOut(uint256,address[])", amountIn, path);

        (bool success, bytes memory result) = _safeStaticCall(UNISWAP_V2_ROUTER, getAmountsData);
        if (success) {
            uint256[] memory amounts = abi.decode(result, (uint256[]));
            return amounts[1];
        } else {
            // Fallback calculation if both fail
            return (amountIn * _state.currentPrice) / Constants.PRICE_PRECISION;
        }
    }

    function _updateLiquidityReserves(
        uint256 amount,
        uint8 /* direction */
    )
        internal
    {
        // Pool balances are updated inside _executeBuyPressure/_executeSellPressure
        // with the actual swap amounts; here we only release the reservation.
        if (_reservedLiquidity >= amount) {
            _reservedLiquidity -= amount;
        } else {
            _reservedLiquidity = 0;
        }
    }

    // ============ EMERGENCY FUNCTIONS ============

    /// @dev Emergency withdrawal function (owner only)
    function emergencyWithdraw() external override onlyOwner {
        uint256 balance = STABLE_TOKEN.balanceOf(address(this));
        if (balance > 0) {
            require(STABLE_TOKEN.transfer(owner(), balance), "Transfer failed");
        }

        if (address(this).balance > 0) {
            payable(owner()).transfer(address(this).balance);
        }

        // The pools are drained: reflect it in the accounting
        _totalEthLiquidity = 0;
        _totalSgdLiquidity = 0;
        _reservedLiquidity = 0;
    }

    /// @dev Accept ETH only from swap flows (router unwinding to ETH) and the
    ///      ArbitrageManager. Plain sends do NOT credit liquidity — use
    ///      provideLiquidity for that.
    receive() external payable {
        if (msg.sender != UNISWAP_V2_ROUTER && msg.sender != address(ARBITRAGE_MANAGER)) {
            revert Unauthorized();
        }
    }
}
