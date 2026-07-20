// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import {ILiquidationManager} from "./interfaces/ILiquidationManager.sol";
import {IStableGuard} from "./interfaces/IStableGuard.sol";

/// @title LiquidationManager - Risk & Calculation Module
/// @dev Pure risk-assessment and conversion math. Liquidations are EXECUTED by
///      StableGuard (direct path) and DutchAuctionManager (auction path); this
///      module never holds funds or moves collateral. Thresholds and the bonus
///      are read from StableGuard's config — the single source of truth.
contract LiquidationManager is ILiquidationManager, Ownable {
    // ============ STATE ============
    IPriceOracle private immutable ORACLE;
    ICollateralManager private immutable COLLATERAL;
    address public stableGuard;

    // ============ CONSTRUCTOR ============
    constructor(address _owner, address _oracle, address _collateral) Ownable(_owner) {
        if (_oracle == address(0) || _collateral == address(0)) revert InvalidAddress();
        ORACLE = IPriceOracle(_oracle);
        COLLATERAL = ICollateralManager(_collateral);
    }

    // ============ ADMIN ============
    function setStableGuard(address _guard) external onlyOwner {
        if (_guard == address(0)) revert InvalidAddress();
        stableGuard = _guard;
    }

    /// @dev Thresholds come from StableGuard; only the wiring lives here
    function getConfig()
        external
        view
        returns (address _stableGuard, uint32 minRatio, uint32 liqThreshold, uint32 bonus)
    {
        (uint64 minR, uint64 liqT,, uint32 b) = _systemConfig();
        return (stableGuard, uint32(minR), uint32(liqT), b);
    }

    // ============ RISK ASSESSMENT ============

    /// @inheritdoc ILiquidationManager
    function isLiquidatable(address user) external override returns (bool) {
        if (user == address(0)) return false;

        uint256 totalCollateralValue = COLLATERAL.getTotalCollateralValue(user);
        if (totalCollateralValue == 0) return false;

        uint256 debtValue = _getDebtValue(user);
        if (debtValue == 0) return false;

        (, uint64 liqThreshold,,) = _systemConfig();
        return (totalCollateralValue * 10000) / debtValue < liqThreshold;
    }

    /// @inheritdoc ILiquidationManager
    function getCollateralRatio(address user) external override returns (uint256) {
        if (user == address(0)) return 0;

        uint256 totalCollateralValue = COLLATERAL.getTotalCollateralValue(user);
        uint256 debtValue = _getDebtValue(user);
        return debtValue == 0 ? type(uint256).max : (totalCollateralValue * 10000) / debtValue;
    }

    /// @inheritdoc ILiquidationManager
    function isPositionSafe(address user, uint256 collateralValue, bool useMinRatio)
        external
        view
        override
        returns (bool)
    {
        if (user == address(0)) return false;
        if (collateralValue == 0) return false;

        uint256 debtValue = _getDebtValue(user);
        if (debtValue == 0) return true;

        (uint64 minRatio, uint64 liqThreshold,,) = _systemConfig();
        uint256 threshold = useMinRatio ? minRatio : liqThreshold;
        return (collateralValue * 10000) / debtValue >= threshold;
    }

    function isPositionSafeForLiquidation(address user) external returns (bool) {
        if (user == address(0)) return false;

        uint256 collateralValue = COLLATERAL.getTotalCollateralValue(user);
        if (collateralValue == 0) return false;

        uint256 debtValue = _getDebtValue(user);
        if (debtValue == 0) return true;

        (, uint64 liqThreshold,,) = _systemConfig();
        return (collateralValue * 10000) / debtValue >= liqThreshold;
    }

    // ============ CONVERSION MATH ============

    /// @inheritdoc ILiquidationManager
    /// @dev Decimal-aware: the returned collateral amount is in the token's own decimals
    function calculateLiquidationAmounts(
        address,
        /* user */
        address token,
        uint256 debtAmount
    )
        external
        override
        returns (uint256 collateralAmount, uint256 liquidationBonus)
    {
        uint256 tokenPrice = ORACLE.getTokenPrice(token);
        if (tokenPrice == 0) revert InvalidAmount();

        (,,, uint32 bonus) = _systemConfig();
        uint256 unit = 10 ** ORACLE.getTokenDecimals(token);

        collateralAmount = (debtAmount * (10000 + bonus) * unit) / (10000 * tokenPrice);
        liquidationBonus = (collateralAmount * bonus) / 10000;
    }

    /// @inheritdoc ILiquidationManager
    /// @dev Assumes an 18-decimal token amount; price in 1e18 USD
    function calculateCollateralFromDebt(uint256 debtValue, uint256 tokenPrice)
        external
        view
        override
        returns (uint256)
    {
        if (debtValue == 0) return 0;
        if (tokenPrice == 0) revert InvalidAmount();

        (, uint64 liqThreshold,,) = _systemConfig();
        return (debtValue * liqThreshold * 1e18) / (10000 * tokenPrice);
    }

    /// @inheritdoc ILiquidationManager
    function getLiquidationConstants() external view override returns (uint256, uint256, uint256) {
        (uint64 minRatio, uint64 liqThreshold,, uint32 bonus) = _systemConfig();
        return (minRatio, liqThreshold, bonus);
    }

    // ============ TOKEN SELECTION ============

    /// @inheritdoc ILiquidationManager
    function findOptimalToken(address user) external override returns (address optimalToken) {
        optimalToken = _findOptimalToken(user);
        if (optimalToken == address(0)) revert NoCollateral();
    }

    /// @inheritdoc ILiquidationManager
    function findOptimalTokenForLiquidation(address user) external override returns (address) {
        if (user == address(0)) return address(0);
        return _findOptimalToken(user);
    }

    function _findOptimalToken(address user) internal returns (address optimal) {
        address[] memory tokens = ORACLE.getSupportedTokens();
        uint256 maxValue;

        unchecked {
            for (uint256 i; i < tokens.length; ++i) {
                address token = tokens[i];
                uint256 balance = COLLATERAL.getUserCollateral(user, token);
                if (balance > 0) {
                    uint256 value = ORACLE.getTokenValueInUsd(token, balance);
                    if (value > maxValue) {
                        maxValue = value;
                        optimal = token;
                    }
                }
            }
        }
    }

    // ============ INTERNAL ============

    function _getDebtValue(address user) internal view returns (uint256) {
        address sg = stableGuard;
        if (sg == address(0)) revert InvalidAddress();
        return IStableGuard(sg).getDebt(user);
    }

    function _systemConfig()
        internal
        view
        returns (uint64 minRatio, uint64 liqThreshold, uint32 emergencyThreshold, uint32 bonus)
    {
        address sg = stableGuard;
        if (sg == address(0)) revert InvalidAddress();
        (minRatio, liqThreshold, emergencyThreshold, bonus,,) = IStableGuard(sg).getSystemConfig();
    }
}
