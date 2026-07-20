// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IRepegManager
 * @dev Interface for the RepegManager contract
 */
interface IRepegManager {
    // ============ STRUCTS ============

    struct RepegConfig {
        uint128 targetPrice;
        uint64 deviationThreshold;
        uint32 repegCooldown;
        uint32 arbitrageWindow;
        uint16 incentiveRate;
        uint8 maxRepegPerDay;
        bool enabled;
    }

    struct RepegState {
        uint128 currentPrice;
        uint64 lastRepegTime;
        uint8 dailyRepegCount;
        uint32 lastResetDay;
        uint8 consecutiveRepegs;
        uint8 repegDirection;
        bool inProgress;
    }

    struct ArbitrageOpportunity {
        address tokenA;
        address tokenB;
        uint256 amountIn;
        uint256 expectedProfit;
        uint128 confidence;
        uint64 expiryTime;
    }

    // ============ EVENTS ============

    event RepegEvent(
        uint8 indexed eventType,
        uint128 oldPrice,
        uint128 newPrice,
        address indexed caller,
        uint128 incentive,
        uint32 timestamp
    );

    /// @dev Distinct name from IArbitrageManager.ArbitrageExecuted (different signature)
    event RepegArbitrageExecuted(uint256 timestamp);

    event RepegOperationExecuted(
        uint128 targetPrice, uint128 currentPrice, uint256 interventionAmount, string strategy, uint256 timestamp
    );

    // ============ CORE FUNCTIONS ============

    /**
     * @dev Check if repeg is needed and trigger if conditions are met.
     *      Only callable by StableGuard, which forwards the end user.
     * @param beneficiary The end user that triggered the repeg (receives the incentive)
     * @return triggered Whether repeg was triggered
     * @return newPrice New price after repeg
     */
    function checkAndTriggerRepeg(address beneficiary) external returns (bool triggered, uint128 newPrice);

    /**
     * @dev Execute repeg with specific parameters
     * @param targetPrice Target price for repeg
     * @param direction Direction of repeg. Convention used across the whole
     *        contract: 0 = none, 1 = buy SGD (price below target, pushes it up),
     *        2 = sell SGD (price above target, pushes it down)
     * @return success Whether repeg was successful
     */
    function executeRepeg(uint128 targetPrice, uint8 direction) external returns (bool success);

    /**
     * @dev Calculate optimal repeg parameters
     * @return targetPrice Calculated target price
     * @return direction Recommended direction
     * @return incentive Calculated incentive amount
     */
    function calculateRepegParameters() external returns (uint128 targetPrice, uint8 direction, uint128 incentive);

    // ============ ARBITRAGE FUNCTIONS ============

    /**
     * @dev Execute arbitrage opportunity
     * @param amount Amount to use for arbitrage
     * @param maxSlippage Maximum acceptable slippage
     * @return profit Profit from arbitrage
     */
    function executeArbitrage(uint256 amount, uint128 maxSlippage) external payable returns (uint128 profit);

    /**
     * @dev Get available arbitrage opportunities
     * @return opportunities Array of available opportunities
     */
    function getArbitrageOpportunities() external returns (ArbitrageOpportunity[] memory opportunities);

    // ============ LIQUIDITY FUNCTIONS ============

    /**
     * @dev Provide liquidity to the repeg pool. ETH (via msg.value) and SGD are
     *      tracked in separate pools; withdrawals repay the deposited asset.
     * @param amount Amount of liquidity to provide
     * @return success Whether provision was successful
     */
    function provideLiquidity(uint256 amount) external payable returns (bool success);

    /**
     * @dev Withdraw SGD liquidity from the repeg pool
     * @param amount Amount of SGD liquidity to withdraw
     * @return success Whether withdrawal was successful
     */
    function withdrawLiquidity(uint256 amount) external returns (bool success);

    /**
     * @dev Withdraw ETH liquidity from the repeg pool
     * @param amount Amount of ETH liquidity to withdraw
     * @return success Whether withdrawal was successful
     */
    function withdrawEthLiquidity(uint256 amount) external returns (bool success);

    // ============ CONFIGURATION FUNCTIONS ============

    /**
     * @dev Update repeg configuration
     * @param newConfig New configuration parameters
     */
    function updateRepegConfig(RepegConfig calldata newConfig) external;

    /**
     * @dev Set emergency pause state
     * @param paused Whether to pause operations
     */
    function setEmergencyPause(bool paused) external;

    /**
     * @dev Update deviation threshold
     * @param newThreshold New threshold value
     */
    function updateDeviationThreshold(uint64 newThreshold) external;

    /**
     * @dev Update incentive parameters
     * @param rate Incentive rate
     * @param maxIncentive Maximum incentive amount
     */
    function updateIncentiveParameters(uint16 rate, uint128 maxIncentive) external;

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get current repeg configuration
     * @return config Current configuration
     */
    function getRepegConfig() external view returns (RepegConfig memory config);

    /**
     * @dev Get current repeg state
     * @return state Current state
     */
    function getRepegState() external view returns (RepegState memory state);

    /**
     * @dev Check if repeg is needed
     * @return needed Whether repeg is needed
     * @return currentDeviation Current price deviation
     */
    function isRepegNeeded() external returns (bool needed, uint128 currentDeviation);

    /**
     * @dev Get current price deviation
     * @return deviation Current deviation amount
     * @return isAbove Whether price is above target
     */
    function getCurrentDeviation() external returns (uint128 deviation, bool isAbove);

    /**
     * @dev Calculate incentive for repeg caller
     * @param caller Address of the caller
     * @return incentive Calculated incentive amount
     */
    function calculateIncentive(address caller) external returns (uint128 incentive);

    /**
     * @dev Get liquidity pool status
     * @return totalLiquidity Total liquidity in pool
     * @return availableLiquidity Available liquidity amount
     */
    function getLiquidityPoolStatus() external view returns (uint256 totalLiquidity, uint256 availableLiquidity);

    /**
     * @dev Get repeg history
     * @param count Number of historical entries to return
     * @return prices Array of historical prices
     * @return timestamps Array of historical timestamps
     */
    function getRepegHistory(uint256 count) external view returns (uint128[] memory prices, uint64[] memory timestamps);

    /**
     * @dev Check if repeg can be triggered
     * @return canTrigger Whether repeg can be triggered
     * @return reason Reason if repeg cannot be triggered
     */
    function canTriggerRepeg() external returns (bool canTrigger, string memory reason);

    /**
     * @dev Get optimal timing for next repeg
     * @return nextOptimalTime Timestamp of next optimal repeg
     * @return confidence Confidence level of timing
     */
    function getOptimalRepegTiming() external returns (uint64 nextOptimalTime, uint32 confidence);

    /**
     * @dev Emergency withdraw function for owner
     */
    function emergencyWithdraw() external;
}
