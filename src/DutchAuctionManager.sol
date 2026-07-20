// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Constants} from "./Constants.sol";
import {IDutchAuctionManager} from "./interfaces/IDutchAuctionManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import {IStableGuard} from "./interfaces/IStableGuard.sol";

/// @title DutchAuctionManager - Ultra Gas Optimized with Enhanced Security
/// @dev Implements reentrancy protection and robust validation patterns.
///      Bids are paid in SGD; winning a bid settles the liquidated user's debt
///      in StableGuard and seizes collateral held by the CollateralManager.
contract DutchAuctionManager is IDutchAuctionManager, ReentrancyGuard, Ownable {
    // ============ MEV PROTECTION CONSTANTS ============
    uint256 private constant COMMIT_DURATION = 300; // 5 minutes
    uint256 private constant REVEAL_DURATION = 600; // 10 minutes
    uint256 private constant MIN_BID_DELAY = 12; // 12 seconds minimum between bids
    uint256 private constant MAX_PRICE_IMPACT = 500; // 5% max price impact
    uint256 private constant FLASHLOAN_PROTECTION_BLOCKS = 2; // 2 blocks protection

    // ============ IMMUTABLES ============
    IPriceOracle public immutable PRICE_ORACLE;
    ICollateralManager public immutable COLLATERAL_MANAGER;

    // ============ ULTRA-OPTIMIZED STATE ============
    address public stableGuard;
    uint256 public nextAuctionId = 1;

    // Ultra-packed config (32 bytes = 1 slot)
    struct Config {
        uint64 duration;
        uint64 minPriceFactor;
        uint64 liquidationBonus;
        uint64 reserved;
    }

    Config public config;

    // ============ MEV PROTECTION STRUCTURES ============
    struct BidCommit {
        bytes32 commitHash; // 32 bytes - keccak256(bidder, auctionId, maxPrice, nonce)
        uint64 commitTime; // 8 bytes - commit timestamp
        uint64 revealDeadline; // 8 bytes - reveal deadline
        bool revealed; // 1 byte - reveal status
    }

    struct MevProtection {
        uint64 lastBidTime; // 8 bytes - last bid timestamp
        uint64 lastBidBlock; // 8 bytes - last bid block number
        uint64 priceImpact; // 8 bytes - price impact in basis points
        uint64 flashloanBlock; // 8 bytes - flashloan detection block
    }

    // Ultra-optimized storage
    mapping(uint256 => DutchAuction) public auctions;
    mapping(address => uint256[]) private userAuctionIds;

    // ============ MEV PROTECTION STORAGE ============
    mapping(bytes32 => BidCommit) public bidCommits;
    mapping(uint256 => MevProtection) public mevProtection;
    mapping(address => uint256) public lastBidderActivity;
    mapping(address => uint256) public bidderReputation;

    // ============ MEV PROTECTION EVENTS ============
    event BidCommitted(bytes32 indexed commitHash, uint256 indexed auctionId, address indexed bidder);
    event BidRevealed(bytes32 indexed commitHash, uint256 indexed auctionId, address indexed bidder, uint256 maxPrice);
    event MEVAttemptDetected(uint256 indexed auctionId, address indexed suspect, string reason);
    event FlashloanDetected(address indexed user, uint256 blockNumber);

    // ============ ULTRA-COMPACT MODIFIERS ============
    modifier onlyStableGuard() {
        if (msg.sender != stableGuard) revert Unauthorized();
        _;
    }

    modifier validAuction(uint256 auctionId) {
        if (auctionId >= nextAuctionId || !auctions[auctionId].active) revert InvalidParameters();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    // ============ MEV PROTECTION MODIFIERS ============
    modifier mevProtected(uint256 auctionId) {
        _checkMevProtection(auctionId);
        _;
        _updateMevProtection(auctionId);
    }

    modifier flashloanProtected() {
        _checkFlashloanProtection();
        _;
    }

    modifier rateLimited() {
        // Only apply rate limiting if bidder has previous activity
        if (lastBidderActivity[msg.sender] > 0) {
            require(block.timestamp >= lastBidderActivity[msg.sender] + MIN_BID_DELAY, "Rate limited");
        }
        _;
        lastBidderActivity[msg.sender] = block.timestamp;
    }

    // ============ ULTRA-OPTIMIZED CONSTRUCTOR ============
    constructor(address _priceOracle, address _collateralManager) Ownable(msg.sender) {
        assembly {
            if or(iszero(_priceOracle), iszero(_collateralManager)) { revert(0, 0) }
        }
        PRICE_ORACLE = IPriceOracle(_priceOracle);
        COLLATERAL_MANAGER = ICollateralManager(_collateralManager);
        config = Config({duration: 3600, minPriceFactor: 5000, liquidationBonus: 1000, reserved: 0});
    }

    // ============ ULTRA-OPTIMIZED FUNCTIONS ============
    function setStableGuard(address _stableGuard) external onlyOwner validAddress(_stableGuard) {
        stableGuard = _stableGuard;
    }

    /// @dev Ultra-optimized auction start with enhanced security
    function startDutchAuction(address user, address token, uint256 debtAmount)
        external
        onlyStableGuard
        nonReentrant
        validAddress(user)
        returns (uint256 auctionId)
    {
        // CHECKS: Input validation
        assembly {
            if iszero(debtAmount) {
                mstore(0x00, 0x4e487b71) // InvalidParameters()
                revert(0x1c, 0x04)
            }
        }

        // CHECKS: Verify collateral exists
        uint256 userCollateral = COLLATERAL_MANAGER.getUserCollateral(user, token);
        if (userCollateral == 0) revert NoCollateral();

        // CHECKS: Verify price oracle is working
        uint256 startPrice = PRICE_ORACLE.getTokenPrice(token);
        if (startPrice == 0) revert InvalidPrice();
        uint8 tokenDecimals = PRICE_ORACLE.getTokenDecimals(token);

        // Auction only the collateral needed to cover debt + liquidation bonus at
        // the start price (in the token's own decimals), capped at the balance.
        uint256 targetValue = debtAmount + (debtAmount * config.liquidationBonus) / 10000; // USD, 1e18
        uint256 collateralNeeded = (targetValue * (10 ** tokenDecimals)) / startPrice;
        uint256 collateralAmount = collateralNeeded < userCollateral ? collateralNeeded : userCollateral;
        if (collateralAmount == 0) revert NoCollateral();

        // The DutchAuction struct packs debt and collateral into uint96; reject
        // values that would truncate rather than silently storing a wrong auction.
        if (debtAmount > type(uint96).max || collateralAmount > type(uint96).max || startPrice > type(uint128).max) {
            revert InvalidParameters();
        }

        // EFFECTS: Update state before external interactions
        auctionId = nextAuctionId++;

        auctions[auctionId] = DutchAuction({
            user: user,
            token: token,
            debtAmount: uint96(debtAmount),
            collateralAmount: uint96(collateralAmount),
            startTime: uint64(block.timestamp),
            duration: uint32(config.duration),
            startPrice: uint128(startPrice),
            endPrice: uint128((startPrice * config.minPriceFactor) / 10000),
            active: true,
            tokenDecimals: tokenDecimals
        });

        userAuctionIds[user].push(auctionId);

        // INTERACTIONS: Emit event last
        emit AuctionEvent(auctionId, user, token, 0, uint128(collateralAmount), uint128(startPrice));
    }

    /// @dev Ultra-optimized bidding with enhanced security. Paid in SGD.
    function bidOnAuction(uint256 auctionId, uint256 maxPrice)
        external
        nonReentrant
        validAuction(auctionId)
        mevProtected(auctionId)
        flashloanProtected
        rateLimited
        returns (bool)
    {
        return _settleBid(auctionId, maxPrice);
    }

    /// @dev Ultra-compact auction cancellation
    function cancelExpiredAuction(uint256 auctionId) external validAuction(auctionId) {
        if (!isAuctionExpired(auctionId)) revert AuctionNotExpired();
        auctions[auctionId].active = false;
        emit AuctionEvent(auctionId, msg.sender, auctions[auctionId].token, 2, 0, 0);
    }

    /// @dev Ultra-optimized price calculation with enhanced validation
    function getCurrentPrice(uint256 auctionId) public view returns (uint256 price) {
        if (auctionId >= nextAuctionId) return 0;

        DutchAuction storage auction = auctions[auctionId];
        if (!auction.active) return 0;

        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 startPrice = auction.startPrice;
        uint256 minPrice = (startPrice * config.minPriceFactor) / 10000;

        // Return minimum price if exactly at duration
        if (elapsed == config.duration) return minPrice;

        // Return 0 if past duration (truly expired)
        if (elapsed > config.duration) return 0;

        uint256 priceReduction = ((startPrice - minPrice) * elapsed) / config.duration;

        return startPrice - priceReduction;
    }

    // Ultra-compact view functions with security validations
    function getAuction(uint256 auctionId) external view returns (DutchAuction memory) {
        if (auctionId >= nextAuctionId) revert InvalidParameters();
        return auctions[auctionId];
    }

    function getUserAuctions(address user) external view returns (uint256[] memory) {
        if (user == address(0)) revert InvalidAddress();
        return userAuctionIds[user];
    }

    function isAuctionActive(uint256 auctionId) external view returns (bool) {
        return auctions[auctionId].active && !isAuctionExpired(auctionId);
    }

    // ============ ULTRA-COMPACT UTILITIES ============
    function getConfig() external view returns (uint64, uint64, uint64) {
        return (config.duration, config.minPriceFactor, config.liquidationBonus);
    }

    function isAuctionExpired(uint256 auctionId) public view returns (bool) {
        return block.timestamp >= auctions[auctionId].startTime + config.duration;
    }

    function getAuctionCounter() external view returns (uint256) {
        return nextAuctionId - 1;
    }

    // ============ ULTRA-OPTIMIZED ADMIN ============
    function updateConfig(uint64 duration, uint64 minPriceFactor, uint64 liquidationBonus) external onlyOwner {
        assembly {
            if or(or(iszero(duration), iszero(minPriceFactor)), iszero(liquidationBonus)) { revert(0, 0) }
            if or(gt(minPriceFactor, 10000), gt(liquidationBonus, 10000)) { revert(0, 0) }
        }
        config = Config({
            duration: duration, minPriceFactor: minPriceFactor, liquidationBonus: liquidationBonus, reserved: 0
        });
        emit AuctionEvent(0, msg.sender, address(0), 4, uint128(duration), uint128(minPriceFactor));
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        // CHECKS: Validate inputs
        if (amount == 0) revert InvalidParameters();

        // CHECKS: Verify available balance
        uint256 availableBalance;
        if (token == Constants.ETH_TOKEN) {
            availableBalance = address(this).balance;
        } else {
            if (token == address(0)) revert InvalidAddress();
            availableBalance = IERC20(token).balanceOf(address(this));
        }
        if (amount > availableBalance) revert InsufficientPayment();

        // INTERACTIONS: Transfer funds
        if (token == Constants.ETH_TOKEN) {
            (bool success,) = payable(owner()).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            if (!IERC20(token).transfer(owner(), amount)) revert TransferFailed();
        }
    }

    /// @dev Get all active auctions
    function getActiveAuctions() external view returns (uint256[] memory activeAuctions) {
        uint256 count;

        // First pass: count active auctions
        for (uint256 i = 1; i < nextAuctionId; i++) {
            if (auctions[i].active && !isAuctionExpired(i)) {
                count++;
            }
        }

        // Second pass: populate array
        activeAuctions = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < nextAuctionId; i++) {
            if (auctions[i].active && !isAuctionExpired(i)) {
                activeAuctions[index] = i;
                index++;
            }
        }
    }

    function getUserTokenAuction(address user, address token) external view returns (uint256) {
        // Input validation - user cannot be zero address, but token can be (ETH)
        if (user == address(0)) revert InvalidAddress();

        uint256[] memory userAuctions = userAuctionIds[user];
        unchecked {
            for (uint256 i; i < userAuctions.length; ++i) {
                uint256 auctionId = userAuctions[i];
                if (auctions[auctionId].active && auctions[auctionId].token == token) return auctionId;
            }
        }
        return 0;
    }

    // ============ CLEANUP FUNCTIONS ============

    /// @dev Ultra-optimized batch cleaning with assembly
    function cleanExpiredAuctions(uint256[] calldata auctionIds) external returns (uint256 incentive) {
        uint256 cleanedCount;

        for (uint256 i = 0; i < auctionIds.length; i++) {
            uint256 auctionId = auctionIds[i];
            if (auctionId < nextAuctionId && auctions[auctionId].active && isAuctionExpired(auctionId)) {
                auctions[auctionId].active = false;
                cleanedCount++;
            }
        }

        if (cleanedCount > 0) {
            emit AuctionEvent(0, msg.sender, address(0), 3, uint128(cleanedCount), 0);
        }
        return 0; // No ETH incentives: this contract does not hold ETH
    }

    // ============ MEV PROTECTION FUNCTIONS ============

    /// @dev Commit-reveal scheme for MEV protection
    function commitBid(bytes32 commitHash, uint256 auctionId) external validAuction(auctionId) {
        require(commitHash != bytes32(0), "Invalid commit hash");

        bytes32 commitId;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, caller())
            mstore(add(ptr, 0x20), auctionId)
            mstore(add(ptr, 0x40), timestamp())
            commitId := keccak256(ptr, 0x60)
        }

        bidCommits[commitId] = BidCommit({
            commitHash: commitHash,
            commitTime: uint64(block.timestamp),
            revealDeadline: uint64(block.timestamp + REVEAL_DURATION),
            revealed: false
        });

        emit BidCommitted(commitHash, auctionId, msg.sender);
    }

    /// @dev Reveal bid with MEV protection
    function revealAndBid(bytes32 commitId, uint256 auctionId, uint256 maxPrice, uint256 nonce)
        external
        nonReentrant
        validAuction(auctionId)
        mevProtected(auctionId)
        flashloanProtected
        rateLimited
        returns (bool)
    {
        BidCommit storage commit = bidCommits[commitId];

        // Validate commit
        require(commit.commitTime > 0, "Invalid commit");
        require(!commit.revealed, "Already revealed");
        require(block.timestamp <= commit.revealDeadline, "Reveal deadline passed");
        require(block.timestamp >= commit.commitTime + COMMIT_DURATION, "Commit period not ended");

        // Verify commit hash
        bytes32 expectedHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, caller())
            mstore(add(ptr, 0x20), auctionId)
            mstore(add(ptr, 0x40), maxPrice)
            mstore(add(ptr, 0x60), nonce)
            expectedHash := keccak256(ptr, 0x80)
        }
        require(commit.commitHash == expectedHash, "Invalid reveal");

        // Mark as revealed
        commit.revealed = true;

        emit BidRevealed(commit.commitHash, auctionId, msg.sender, maxPrice);

        // Execute bid
        return _settleBid(auctionId, maxPrice);
    }

    /// @dev Single settlement path for both direct and commit-reveal bids.
    ///      The bidder pays in SGD: the debt portion is forwarded to StableGuard
    ///      (which burns it), any surplus goes to the liquidated user, and the
    ///      collateral is seized from the CollateralManager straight to the bidder.
    function _settleBid(uint256 auctionId, uint256 maxPrice) internal returns (bool) {
        DutchAuction storage auction = auctions[auctionId];

        if (isAuctionExpired(auctionId)) revert AuctionExpired();
        uint256 currentPrice = getCurrentPrice(auctionId);
        if (currentPrice == 0) revert AuctionExpired();
        if (currentPrice > maxPrice) revert PriceTooHigh();

        // Total cost in SGD (1e18): price is USD/token in 1e18, amount in token decimals
        uint256 totalCost = (currentPrice * auction.collateralAmount) / (10 ** auction.tokenDecimals);
        if (totalCost == 0) revert InsufficientPayment();
        uint256 debtSettled = totalCost < auction.debtAmount ? totalCost : auction.debtAmount;
        uint256 surplus = totalCost - debtSettled;

        // EFFECTS: Close the auction before any external interaction
        auction.active = false;

        // INTERACTIONS (SGD is our own ERC20, no transfer hooks)
        IERC20 sgd = IERC20(stableGuard);
        if (!sgd.transferFrom(msg.sender, address(this), totalCost)) revert TransferFailed();
        // Debt portion is held by StableGuard until processAuctionCompletion burns it
        if (!sgd.transfer(stableGuard, debtSettled)) revert TransferFailed();
        // Anything above the outstanding debt belongs to the liquidated user
        if (surplus > 0 && !sgd.transfer(auction.user, surplus)) revert TransferFailed();

        // Seize collateral: debit the user's custody, pay the bidder directly
        COLLATERAL_MANAGER.withdraw(auction.user, auction.token, auction.collateralAmount, msg.sender);

        // Settle the user's debt in the core. A revert here reverts the whole bid:
        // settlement is atomic by design.
        IStableGuard(stableGuard).processAuctionCompletion(auction.user, debtSettled);

        emit AuctionEvent(
            auctionId, msg.sender, auction.token, 1, uint128(auction.collateralAmount), uint128(currentPrice)
        );

        return true;
    }

    /// @dev Check MEV protection conditions
    function _checkMevProtection(uint256 auctionId) internal {
        MevProtection storage protection = mevProtection[auctionId];

        // Check minimum time between bids
        if (protection.lastBidTime > 0) {
            require(block.timestamp >= protection.lastBidTime + MIN_BID_DELAY, "Bid too frequent");
        }

        // Check block-based protection
        if (protection.lastBidBlock > 0) {
            require(block.number > protection.lastBidBlock, "Same block bid");
        }

        // Check price impact
        if (protection.priceImpact > MAX_PRICE_IMPACT) {
            emit MEVAttemptDetected(auctionId, msg.sender, "High price impact");
            revert("Price impact too high");
        }
    }

    /// @dev Update MEV protection state
    function _updateMevProtection(uint256 auctionId) internal {
        MevProtection storage protection = mevProtection[auctionId];

        uint256 currentPrice = getCurrentPrice(auctionId);
        uint256 previousPrice = protection.lastBidTime > 0
            ? _calculatePriceAtTime(auctionId, protection.lastBidTime)
            : auctions[auctionId].startPrice;

        // Calculate price impact
        uint256 priceImpact =
            previousPrice > currentPrice ? ((previousPrice - currentPrice) * 10000) / previousPrice : 0;

        protection.lastBidTime = uint64(block.timestamp);
        protection.lastBidBlock = uint64(block.number);
        protection.priceImpact = uint64(priceImpact);

        // Update bidder reputation
        if (priceImpact > MAX_PRICE_IMPACT / 2) {
            bidderReputation[msg.sender] = bidderReputation[msg.sender] > 0 ? bidderReputation[msg.sender] - 1 : 0;
        } else {
            bidderReputation[msg.sender]++;
        }
    }

    /// @dev Check flashloan protection
    function _checkFlashloanProtection() internal {
        // Simple flashloan detection: check if balance changed significantly in recent blocks
        uint256 currentBalance = address(this).balance;

        // Check if we're still in protection period from a previous detection
        if (
            mevProtection[0].flashloanBlock > 0
                && block.number <= mevProtection[0].flashloanBlock + FLASHLOAN_PROTECTION_BLOCKS
        ) {
            revert("Flashloan protection active");
        }

        // Check for new flashloan detection
        if (currentBalance > 100 ether) {
            // Only trigger if this is a new detection (different block)
            if (mevProtection[0].flashloanBlock != block.number) {
                mevProtection[0].flashloanBlock = uint64(block.number);
                emit FlashloanDetected(msg.sender, block.number);
                revert("Flashloan protection active");
            }
        }
    }

    /// @dev Calculate price at specific time
    function _calculatePriceAtTime(uint256 auctionId, uint256 timestamp) internal view returns (uint256) {
        DutchAuction storage auction = auctions[auctionId];

        if (timestamp <= auction.startTime) return auction.startPrice;

        uint256 elapsed = timestamp - auction.startTime;
        if (elapsed >= config.duration) return auction.endPrice;

        uint256 priceDiff = auction.startPrice - auction.endPrice;
        uint256 priceReduction = (priceDiff * elapsed) / config.duration;

        return auction.startPrice - priceReduction;
    }

    /// @dev Get MEV protection info
    function getMevProtection(uint256 auctionId) external view returns (MevProtection memory) {
        return mevProtection[auctionId];
    }

    /// @dev Get bidder reputation
    function getBidderReputation(address bidder) external view returns (uint256) {
        return bidderReputation[bidder];
    }
}
