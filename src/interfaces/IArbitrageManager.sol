// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IArbitrageManager
 * @dev Interface for the ArbitrageManager contract
 */
interface IArbitrageManager {
    // ============ STRUCTS ============

    struct ArbitrageConfig {
        uint256 maxTradeSize;
        uint256 minProfitBps;
        uint256 maxSlippageBps;
        bool enabled;
    }

    // ============ EVENTS ============

    event ArbitrageExecuted(
        address indexed dexFrom,
        address indexed dexTo,
        uint256 amountIn,
        uint256 amountOut,
        uint256 profit,
        uint256 timestamp
    );

    event ConfigUpdated(uint256 maxTradeSize, uint256 minProfitBps, uint256 maxSlippageBps, bool enabled);

    // ============ CORE FUNCTIONS ============

    /**
     * @dev Execute arbitrage opportunity
     * Scans for price differences and executes profitable trades
     */
    function executeArbitrage() external;

    /**
     * @dev Update circuit breaker state by testing DEX connectivity
     * This allows the circuit breaker to be updated in a separate transaction
     */
    function updateCircuitBreakerState() external;

    /**
     * @dev Check if arbitrage opportunity exists
     * @return exists Whether profitable arbitrage opportunity exists
     * @return expectedProfit Expected profit in basis points
     */
    function checkArbitrageOpportunity() external view returns (bool exists, uint256 expectedProfit);

    /**
     * @dev Get current arbitrage configuration
     * @return config Current configuration
     */
    function getConfig() external view returns (ArbitrageConfig memory config);

    // ============ CONFIGURATION FUNCTIONS ============

    /**
     * @dev Update arbitrage configuration
     * @param maxTradeSize Maximum trade size
     * @param minProfitBps Minimum profit in basis points
     * @param maxSlippageBps Maximum slippage in basis points
     * @param enabled Whether arbitrage is enabled
     */
    function updateConfig(uint256 maxTradeSize, uint256 minProfitBps, uint256 maxSlippageBps, bool enabled) external;

    /**
     * @dev Emergency withdrawal function
     * @param token Token to withdraw (address(0) for ETH)
     */
    function emergencyWithdraw(address token) external;

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get last arbitrage execution time
     * @return timestamp Last execution timestamp
     */
    function getLastArbitrageTime() external view returns (uint256 timestamp);

    /**
     * @dev Get current DEX price for the stable token
     * @return price Current price from DEX
     */
    function getCurrentDexPrice() external view returns (uint256 price);
}
