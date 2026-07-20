// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IPriceOracle - Ultra Gas Optimized Interface
 * @dev Minimalist interface with maximum gas efficiency
 */
interface IPriceOracle {
    // ============ EVENTS ============

    /// @dev Consolidated event for all token operations (saves gas vs separate events)
    event TokenConfigured(address indexed token, address indexed priceFeed, uint256 fallbackPrice, bool isAdded);
    event FallbackPriceUsed(address indexed token, uint256 price);
    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event FallbackPriceUpdated(address indexed token, uint256 newPrice);

    // ============ CORE FUNCTIONS ============

    /// @dev Get token price with automatic fallback
    function getTokenPrice(address token) external returns (uint256);

    /// @dev Get token price with fallback monitoring (emits events)
    function getTokenPriceWithEvents(address token) external returns (uint256);

    /// @dev Configure token (add/update in single call)
    function configureToken(address token, address priceFeed, uint256 fallbackPrice, uint8 decimals) external;

    /// @dev Remove token support
    function removeToken(address token) external;

    /// @dev Batch configure multiple tokens (gas efficient)
    function batchConfigureTokens(
        address[] calldata tokens,
        address[] calldata priceFeeds,
        uint256[] calldata fallbackPrices,
        uint8[] calldata decimals
    ) external;

    // ============ VIEW FUNCTIONS ============

    function isSupportedToken(address token) external view returns (bool);
    function getSupportedTokens() external view returns (address[] memory);
    function getTokenValueInUsd(address token, uint256 amount) external returns (uint256);
    /// @dev Convert a USD value (1e18) into a token amount in the token's own decimals
    function getTokenAmountFromUsd(address token, uint256 usdValue) external returns (uint256);
    function getTokenConfig(address token)
        external
        view
        returns (address priceFeed, uint256 fallbackPrice, uint8 decimals);
    function getTokenDecimals(address token) external view returns (uint8);

    // ============ CHAINLINK ENHANCED FUNCTIONS ============

    /// @dev Get multiple token prices efficiently
    function getMultipleTokenPrices(address[] calldata tokens)
        external
        returns (uint256[] memory prices, bool[] memory validFlags);

    /// @dev Check Chainlink feed health
    function checkFeedHealth(address token) external view returns (bool isHealthy, uint256 lastUpdate);

    /// @dev Emergency fallback price update
    function updateFallbackPrice(address token, uint256 newFallbackPrice) external;
}
