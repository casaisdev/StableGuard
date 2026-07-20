// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IStableGuard - Settlement surface of the StableGuard core
/// @dev Minimal interface for modules that need to settle debt against the core
interface IStableGuard {
    /// @dev Clears up to `debtSettled` of `user`'s debt and burns the SGD the
    ///      caller transferred beforehand. Only callable by the DutchAuctionManager.
    function processAuctionCompletion(address user, uint256 debtSettled) external;

    /// @dev Outstanding SGD debt of a user
    function getDebt(address user) external view returns (uint256);

    /// @dev System risk parameters (basis points) — the single source of truth.
    ///      Field-compatible with StableGuard.getSystemConfig(), which returns its
    ///      PackedConfig struct (identical ABI encoding).
    function getSystemConfig()
        external
        view
        returns (
            uint64 minCollateralRatio,
            uint64 liquidationThreshold,
            uint32 emergencyThreshold,
            uint32 maxLiquidationBonus,
            uint32 emergencyDelay,
            uint32 reserved
        );
}
