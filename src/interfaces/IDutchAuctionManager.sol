// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IDutchAuctionManager - Ultra Gas Optimized Interface
interface IDutchAuctionManager {
    // ============ ERRORS ============
    error InvalidParameters();
    error InvalidAddress();
    error NoCollateral();
    error AuctionExpired();
    error AuctionNotExpired();
    error PriceTooHigh();
    error InsufficientPayment();
    error TransferFailed();
    error Unauthorized();
    error InvalidPrice();

    // ============ ULTRA-PACKED STRUCT ============
    struct DutchAuction {
        address user; // 20 bytes - User being liquidated
        address token; // 20 bytes - Collateral token
        uint96 debtAmount; // 12 bytes - Debt (supports up to 79B tokens)
        uint96 collateralAmount; // 12 bytes - Collateral amount
        uint64 startTime; // 8 bytes - Start timestamp
        uint32 duration; // 4 bytes - Duration (up to 136 years)
        uint128 startPrice; // 16 bytes - Start price
        uint128 endPrice; // 16 bytes - End price
        bool active; // 1 byte - Active status
        uint8 tokenDecimals; // 1 byte - Cached collateral token decimals
    }

    // ============ CONSOLIDATED EVENTS ============
    /// @dev Single event for all auction state changes (saves deployment gas)
    event AuctionEvent( // 0=Started, 1=Bid, 2=Finished, 3=Cleaned
        uint256 indexed auctionId,
        address indexed userOrWinner,
        address indexed token,
        uint8 eventType,
        uint128 amount,
        uint128 price
    );

    // ============ ULTRA-COMPACT FUNCTIONS ============
    function startDutchAuction(address user, address token, uint256 debtAmount) external returns (uint256);
    /// @dev Bids are paid in SGD (the stablecoin), never in ETH or the collateral token
    function bidOnAuction(uint256 auctionId, uint256 maxPrice) external returns (bool);
    function getCurrentPrice(uint256 auctionId) external view returns (uint256);
    function getAuction(uint256 auctionId) external view returns (DutchAuction memory);
    function getActiveAuctions() external view returns (uint256[] memory);
    function getUserTokenAuction(address user, address token) external view returns (uint256);
    function cleanExpiredAuctions(uint256[] calldata auctionIds) external returns (uint256);
    function isAuctionExpired(uint256 auctionId) external view returns (bool);
    function getAuctionCounter() external view returns (uint256);
    function emergencyWithdraw(address token, uint256 amount) external;
}
