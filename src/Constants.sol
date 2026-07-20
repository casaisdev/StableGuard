// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Constants
 * @dev Shared protocol constants. Per-token configuration (price feeds, decimals,
 *      fallback prices) lives in PriceOracle via configureToken — not here.
 */
library Constants {
    // ============ ADDRESSES ============

    /// @dev Sentinel for native ETH
    address internal constant ETH_TOKEN = address(0);

    /// @dev Mainnet WETH (used by RepegManager/ArbitrageManager swap paths)
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Mainnet Uniswap V2 Router02
    address internal constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // ============ SYSTEM CONFIGURATION ============

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRICE_PRECISION = 1e18;

    // Arbitrage configuration
    uint256 public constant MIN_ARBITRAGE_PROFIT = 50; // 0.5%
    uint256 public constant MAX_ARBITRAGE_SLIPPAGE = 300; // 3%
    uint256 public constant ARBITRAGE_COOLDOWN = 60; // 1 minute per-caller cooldown

    // Repeg configuration
    uint256 public constant REPEG_DEVIATION_THRESHOLD = 500; // 5%
    uint256 public constant REPEG_COOLDOWN = 3600; // 1 hour
    uint256 public constant REPEG_ARBITRAGE_WINDOW = 1800; // 30 minutes
    uint256 public constant REPEG_INCENTIVE_RATE = 100; // 1%
    uint256 public constant MAX_REPEG_PER_DAY = 10;
}
