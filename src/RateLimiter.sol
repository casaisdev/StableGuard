// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title RateLimiter
 * @dev Per-user and global rate limiting extracted from StableGuard into an
 *      external library. Its `public` functions are deployed once and linked via
 *      delegatecall, so this logic lives outside the StableGuard bytecode (which
 *      would otherwise exceed the 24576-byte contract-size limit). The library
 *      operates directly on StableGuard's storage passed by reference.
 */
library RateLimiter {
    // ============ CONSTANTS ============
    uint256 internal constant RATE_LIMIT_WINDOW = 1 hours;
    uint256 internal constant MAX_OPERATIONS_PER_HOUR = 10;
    uint256 internal constant MAX_VOLUME_PER_HOUR = 100000 ether; // 100k USD equivalent
    uint256 internal constant COOLDOWN_PERIOD = 5 minutes;
    uint256 internal constant BURST_LIMIT = 3; // Max operations in burst
    uint256 internal constant BURST_WINDOW = 1 minutes;
    uint256 internal constant GLOBAL_MAX_OPERATIONS = MAX_OPERATIONS_PER_HOUR * 100; // 100x user limit

    // ============ STRUCTS ============
    struct RateLimitData {
        uint64 lastOperationTime; // 8 bytes - Last operation timestamp
        uint32 operationCount; // 4 bytes - Operations in current window
        uint32 burstCount; // 4 bytes - Operations in burst window
        uint64 windowStart; // 8 bytes - Current window start
        uint64 burstWindowStart; // 8 bytes - Burst window start
        uint128 volumeInWindow; // 16 bytes - Volume in current window
        // Total: 48 bytes (2 storage slots)
    }

    struct GlobalRateLimit {
        uint64 lastGlobalOperation; // 8 bytes - Last global operation
        uint32 globalOperationCount; // 4 bytes - Global operations count
        uint64 globalWindowStart; // 8 bytes - Global window start
        uint128 globalVolumeInWindow; // 16 bytes - Global volume in window
        // Total: 40 bytes (2 storage slots)
    }

    // ============ EVENTS ============
    event RateLimitExceeded(address indexed user, string operation, uint256 attemptedVolume, uint256 currentCount);
    event RateLimitUpdated(address indexed user, string operation, uint256 newCount, uint256 newVolume);

    /**
     * @dev Check and consume a user's rate-limit budget for one operation.
     * @return allowed True if the operation is permitted (and was recorded)
     */
    function checkAndConsume(
        mapping(address => RateLimitData) storage limits,
        address user,
        string memory operation,
        uint256 volume
    ) public returns (bool allowed) {
        RateLimitData storage userLimit = limits[user];
        uint256 currentTime = block.timestamp;

        // Reset window if expired
        if (currentTime >= userLimit.windowStart + RATE_LIMIT_WINDOW) {
            userLimit.windowStart = uint64(currentTime);
            userLimit.operationCount = 0;
            userLimit.volumeInWindow = 0;
        }

        // Reset burst window if expired
        if (currentTime >= userLimit.burstWindowStart + BURST_WINDOW) {
            userLimit.burstWindowStart = uint64(currentTime);
            userLimit.burstCount = 0;
        }

        // Check burst limit
        if (userLimit.burstCount >= BURST_LIMIT) {
            emit RateLimitExceeded(user, operation, volume, userLimit.burstCount);
            return false;
        }

        // Check hourly limits
        if (
            userLimit.operationCount >= MAX_OPERATIONS_PER_HOUR
                || userLimit.volumeInWindow + volume > MAX_VOLUME_PER_HOUR
        ) {
            emit RateLimitExceeded(user, operation, volume, userLimit.operationCount);
            return false;
        }

        // Check cooldown
        if (currentTime < userLimit.lastOperationTime + COOLDOWN_PERIOD) {
            emit RateLimitExceeded(user, operation, volume, userLimit.operationCount);
            return false;
        }

        // All checks passed - update limits
        userLimit.lastOperationTime = uint64(currentTime);
        userLimit.operationCount++;
        userLimit.burstCount++;
        userLimit.volumeInWindow += uint128(volume);

        emit RateLimitUpdated(user, operation, userLimit.operationCount, userLimit.volumeInWindow);
        return true;
    }

    /**
     * @dev Enforce and update the global rate limit. Reverts if the global
     *      operation cap for the window is exceeded.
     */
    function consumeGlobal(
        GlobalRateLimit storage g,
        mapping(bytes32 => uint256) storage operationCounts,
        string memory operation,
        uint256 volume
    ) public {
        uint256 currentTime = block.timestamp;

        // Reset global window if expired
        if (currentTime >= g.globalWindowStart + RATE_LIMIT_WINDOW) {
            g.globalWindowStart = uint64(currentTime);
            g.globalOperationCount = 0;
            g.globalVolumeInWindow = 0;
        }

        require(g.globalOperationCount < GLOBAL_MAX_OPERATIONS, "Global rate limit exceeded");

        // Update global counters
        g.lastGlobalOperation = uint64(currentTime);
        g.globalOperationCount++;
        g.globalVolumeInWindow += uint128(volume);

        operationCounts[keccak256(bytes(operation))]++;
    }

    /**
     * @dev Read-only projection of whether `user` could perform an operation now.
     */
    function status(mapping(address => RateLimitData) storage limits, address user, uint256 volume)
        public
        view
        returns (bool)
    {
        RateLimitData memory userLimit = limits[user];
        uint256 currentTime = block.timestamp;

        if (currentTime >= userLimit.windowStart + RATE_LIMIT_WINDOW) {
            userLimit.operationCount = 0;
            userLimit.volumeInWindow = 0;
        }
        if (currentTime >= userLimit.burstWindowStart + BURST_WINDOW) {
            userLimit.burstCount = 0;
        }

        return userLimit.burstCount < BURST_LIMIT && userLimit.operationCount < MAX_OPERATIONS_PER_HOUR
            && userLimit.volumeInWindow + volume <= MAX_VOLUME_PER_HOUR
            && currentTime >= userLimit.lastOperationTime + COOLDOWN_PERIOD;
    }
}
