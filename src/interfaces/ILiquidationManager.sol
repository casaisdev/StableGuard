// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ILiquidationManager - Ultra-Optimized Interface
 * @dev Minimal gas-optimized interface for liquidation management
 */
/// @dev Risk & calculation module: liquidations are executed by StableGuard and
///      DutchAuctionManager; this module only assesses and converts.
interface ILiquidationManager {
    // ============ ERRORS ============
    error Unauthorized();
    error InvalidAmount();
    error InvalidAddress();
    error NoCollateral();

    // ============ VIEW FUNCTIONS ============

    /// @dev Check if position is liquidatable
    function isLiquidatable(address user) external returns (bool);

    /// @dev Calculate liquidation amounts
    function calculateLiquidationAmounts(address user, address token, uint256 debtAmount)
        external
        returns (uint256 collateralAmount, uint256 liquidationBonus);

    /// @dev Get collateral ratio for user
    function getCollateralRatio(address user) external returns (uint256);

    /// @dev Find optimal token for liquidation
    function findOptimalToken(address user) external returns (address optimalToken);

    /// @dev Check if position is safe
    function isPositionSafe(address user, uint256 collateralValue, bool useMinRatio) external view returns (bool);

    /// @dev Calculate collateral from debt
    function calculateCollateralFromDebt(uint256 debtValue, uint256 tokenPrice) external view returns (uint256);

    /// @dev Find optimal token for liquidation (alternative signature)
    function findOptimalTokenForLiquidation(address user) external returns (address);

    /// @dev Get liquidation thresholds (read from StableGuard's config)
    function getLiquidationConstants() external view returns (uint256, uint256, uint256);
}
