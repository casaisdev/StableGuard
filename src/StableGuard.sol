// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import {IDutchAuctionManager} from "./interfaces/IDutchAuctionManager.sol";
import {ILiquidationManager} from "./interfaces/ILiquidationManager.sol";
import {IRepegManager} from "./interfaces/IRepegManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Timelock} from "./Timelock.sol";
import {Constants} from "./Constants.sol";
import {RateLimiter} from "./RateLimiter.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StableGuard - Optimized
 * @dev Gas-optimized multi-collateral stablecoin with packed structs and consolidated functions
 */
contract StableGuard is ERC20, ReentrancyGuard {
    // ============ ULTRA-PACKED STRUCTS ============

    struct UserPosition {
        uint128 debt; // 16 bytes - User's debt amount
        uint64 lastUpdate; // 8 bytes - Last position update timestamp
        uint32 riskScore; // 4 bytes - Cached risk score (scaled)
        uint32 flags; // 4 bytes - Packed flags (liquidatable, emergency, etc.)
        // Total: 32 bytes (1 storage slot)
    }

    struct PackedConfig {
        uint64 minCollateralRatio; // 8 bytes - 150% = 15000 basis points
        uint64 liquidationThreshold; // 8 bytes - 120% = 12000 basis points
        uint32 emergencyThreshold; // 4 bytes - 110% = 11000 basis points
        uint32 maxLiquidationBonus; // 4 bytes - Max liquidation bonus
        uint32 emergencyDelay; // 4 bytes - Emergency action delay
        uint32 reserved; // 4 bytes - Reserved for future use
        // Total: 32 bytes (1 storage slot)
    }

    struct PackedModules {
        IPriceOracle priceOracle; // 20 bytes
        ICollateralManager collateralManager; // 20 bytes
        ILiquidationManager liquidationManager; // 20 bytes
        IDutchAuctionManager dutchAuctionManager; // 20 bytes
        IRepegManager repegManager; // 20 bytes
        // Total: 100 bytes (5 storage slots, one address per slot)
    }

    // ============ CONSTANTS ============

    // Rate-limiting types, constants, and heavy logic live in the RateLimiter
    // library (linked externally to keep StableGuard under the size limit).
    using RateLimiter for mapping(address => RateLimiter.RateLimitData);

    // ============ OPTIMIZED STATE ============

    address private immutable OWNER;
    Timelock public immutable TIMELOCK;

    // Ultra-packed configuration (1 slot)
    PackedConfig private config;

    // Ultra-packed modules (3 slots)
    PackedModules private modules;

    // Optimized user positions
    mapping(address => UserPosition) private positions;

    // ============ RATE LIMITING STATE ============

    // User-specific rate limiting
    mapping(address => RateLimiter.RateLimitData) private userRateLimits;

    // Global rate limiting
    RateLimiter.GlobalRateLimit private globalRateLimit;

    // Operation type tracking
    mapping(bytes32 => uint256) private operationCounts; // operationType => count

    // Emergency pause for rate limiting
    bool private rateLimitingPaused;

    // ============ EVENTS ============

    event PositionUpdated(address indexed user, uint256 debt, uint256 collateralValue);
    event PositionLiquidated(
        address indexed user, address indexed liquidator, uint256 debtAmount, uint256 collateralAmount
    );
    event LiquidationTriggered(address indexed user, address indexed token, uint256 debtAmount, uint256 auctionId);
    event ModulesUpdated(
        address priceOracle,
        address collateralManager,
        address liquidationManager,
        address dutchAuctionManager,
        address repegManager
    );

    // ============ RATE LIMITING EVENTS ============
    // RateLimitExceeded/RateLimitUpdated are emitted from the RateLimiter library.

    event RateLimitingPauseChanged(bool paused, address indexed admin);

    // ============ REPEG MONITORING EVENTS ============

    /// @dev Consolidated event for repeg monitoring (saves gas vs separate events)
    event RepegMonitoring( // 0: check, 1: trigger, 2: arbitrage, 3: liquidity
        address indexed caller,
        uint8 indexed eventType,
        uint128 priceDeviation,
        uint128 incentiveAmount,
        uint256 timestamp
    );

    /// @dev Event for repeg configuration changes
    event RepegConfigUpdated(address indexed updater, uint128 newThreshold, uint128 newIncentive, bool emergencyPause);

    /// @dev Event for liquidity operations
    event RepegLiquidityOperation(
        address indexed provider, bool indexed isDeposit, uint256 amount, uint256 totalLiquidity
    );

    // ============ ULTRA-COMPACT MODIFIERS ============

    modifier onlyOwner() {
        require(msg.sender == OWNER, "Only owner");
        _;
    }

    /// @dev Governance actions must be routed through the Timelock (queue + delay)
    modifier onlyTimelock() {
        require(msg.sender == address(TIMELOCK), "Only timelock");
        _;
    }

    modifier validModules() {
        assembly {
            let modulesSlot := modules.slot
            let oracle := sload(modulesSlot)
            let collateral := sload(add(modulesSlot, 1))
            let liquidation := sload(add(modulesSlot, 2))
            let dutchAuction := sload(add(modulesSlot, 3))
            let repeg := sload(add(modulesSlot, 4))
            if or(
                or(or(iszero(oracle), iszero(collateral)), or(iszero(liquidation), iszero(dutchAuction))),
                iszero(repeg)
            ) {
                mstore(0x00, 0xd92e233d) // "Invalid modules"
                revert(0x1c, 0x04)
            }
        }
        _;
    }

    modifier validPosition(address user) {
        assembly {
            mstore(0x00, user)
            mstore(0x20, positions.slot)
            let positionSlot := keccak256(0x00, 0x40)
            let debt := sload(positionSlot)
            if iszero(debt) {
                mstore(0x00, 0x7c946ed7) // "No position"
                revert(0x1c, 0x04)
            }
        }
        _;
    }

    // ============ OPTIMIZED CONSTRUCTOR ============

    constructor(
        address _priceOracle,
        address _collateralManager,
        address _liquidationManager,
        address _dutchAuctionManager,
        address _repegManager,
        address _timelock
    ) ERC20("StableGuard", "SGD") {
        assembly {
            if or(
                or(
                    or(iszero(_priceOracle), iszero(_collateralManager)),
                    or(iszero(_liquidationManager), iszero(_dutchAuctionManager))
                ),
                or(iszero(_repegManager), iszero(_timelock))
            ) {
                mstore(0x00, 0xd92e233d) // "Invalid addresses"
                revert(0x1c, 0x04)
            }
        }

        OWNER = msg.sender;
        // The Timelock is deployed separately (owned by the deployer/multisig) and
        // wired in here, so governance changes actually pass through its delay.
        TIMELOCK = Timelock(payable(_timelock));

        // Initialize ultra-packed modules
        modules = PackedModules({
            priceOracle: IPriceOracle(_priceOracle),
            collateralManager: ICollateralManager(_collateralManager),
            liquidationManager: ILiquidationManager(_liquidationManager),
            dutchAuctionManager: IDutchAuctionManager(_dutchAuctionManager),
            repegManager: IRepegManager(_repegManager)
        });

        // Initialize ultra-packed configuration with assembly optimization
        assembly {
            let configSlot := config.slot
            // Pack all config values into one storage write
            let packedConfig := or(or(or(15000, shl(64, 12000)), or(shl(128, 11000), shl(160, 1000))), shl(192, 3600))
            sstore(configSlot, packedConfig)
        }
    }

    // ============ OPTIMIZED CORE FUNCTIONS ============

    /**
     * @dev Unified deposit and mint (supports both ETH and ERC20)
     * @param token Address of token (use ETH_TOKEN for ETH)
     * @param depositAmount Amount to deposit (ignored for ETH, uses msg.value)
     * @param mintAmount Amount of stablecoin to mint
     */
    function depositAndMint(address token, uint256 depositAmount, uint256 mintAmount)
        external
        payable
        validModules
        nonReentrant
        rateLimited("DEPOSIT", msg.value > 0 ? msg.value : depositAmount)
        globalRateLimited("DEPOSIT", msg.value > 0 ? msg.value : depositAmount)
    {
        bool isEth = (token == Constants.ETH_TOKEN);
        uint256 actualDepositAmount = isEth ? msg.value : depositAmount;
        _processDepositAndMint(token, actualDepositAmount, mintAmount, isEth);
    }

    /**
     * @dev Ultra-optimized internal deposit and mint logic
     */
    function _processDepositAndMint(address token, uint256 depositAmount, uint256 mintAmount, bool isEth) internal {
        // ============ CHECKS ============
        // Assembly-optimized validation
        assembly {
            if or(iszero(depositAmount), iszero(mintAmount)) {
                mstore(0x00, 0x7c946ed7) // "Invalid amounts"
                revert(0x1c, 0x04)
            }
        }

        if (!isEth) {
            require(modules.priceOracle.isSupportedToken(token), "Token not supported");
        }

        UserPosition storage position = positions[msg.sender];

        // Calculate new position values
        uint256 currentCollateralValue = modules.collateralManager.getTotalCollateralValue(msg.sender);
        uint256 newCollateralValue =
            currentCollateralValue + modules.priceOracle.getTokenValueInUsd(token, depositAmount);
        uint256 newDebt = position.debt + mintAmount;

        // Verify collateralization ratio
        require(_isPositionSafe(newCollateralValue, newDebt), "Insufficient collateral");

        // ============ EFFECTS ============
        // Ultra-optimized position update with assembly
        uint256 basisPoints = Constants.BASIS_POINTS;
        assembly {
            let positionSlot := position.slot
            // Update debt (first 128 bits)
            sstore(positionSlot, or(and(sload(positionSlot), not(0xffffffffffffffffffffffffffffffff)), newDebt))
            // Update timestamp, risk score, and preserve flags
            let riskScore := and(div(mul(newCollateralValue, basisPoints), newDebt), 0xffffffff)
            let newData :=
                or(or(shl(224, timestamp()), shl(192, riskScore)), and(sload(add(positionSlot, 1)), 0xffffffff))
            sstore(add(positionSlot, 1), newData)
        }

        _mint(msg.sender, mintAmount);

        // ============ INTERACTIONS ============
        if (!isEth) {
            require(
                IERC20(token).transferFrom(msg.sender, address(modules.collateralManager), depositAmount),
                "Transfer failed"
            );
        }

        // Update collateral
        modules.collateralManager.deposit{value: isEth ? depositAmount : 0}(msg.sender, token, depositAmount);

        emit PositionUpdated(msg.sender, newDebt, newCollateralValue);
    }

    /**
     * @dev Unified burn and withdraw (supports both ETH and ERC20)
     * @param token Address of token (use Constants.ETH_TOKEN for ETH)
     * @param burnAmount Amount of stablecoin to burn
     * @param withdrawAmount Amount of collateral to withdraw
     */
    function burnAndWithdraw(address token, uint256 burnAmount, uint256 withdrawAmount)
        external
        validModules
        nonReentrant
        rateLimited("WITHDRAW", withdrawAmount)
        globalRateLimited("WITHDRAW", withdrawAmount)
    {
        bool isEth = (token == Constants.ETH_TOKEN);
        _processBurnAndWithdraw(token, burnAmount, withdrawAmount, isEth);
    }

    /**
     * @dev Ultra-optimized internal burn and withdraw logic
     */
    function _processBurnAndWithdraw(address token, uint256 burnAmount, uint256 withdrawAmount, bool isEth) internal {
        // ============ CHECKS ============
        UserPosition storage position = positions[msg.sender];

        // Assembly-optimized validation batch
        assembly {
            if or(iszero(burnAmount), iszero(withdrawAmount)) {
                mstore(0x00, 0x7c946ed7) // "Invalid amounts"
                revert(0x1c, 0x04)
            }

            // Check debt sufficiency
            let currentDebt := and(sload(position.slot), 0xffffffffffffffffffffffffffffffff)
            if lt(currentDebt, burnAmount) {
                mstore(0x00, 0x356680b7) // "Insufficient debt"
                revert(0x1c, 0x04)
            }
        }

        require(balanceOf(msg.sender) >= burnAmount, "Insufficient balance");
        require(
            modules.collateralManager.getUserCollateral(msg.sender, token) >= withdrawAmount, "Insufficient collateral"
        );
        if (!isEth) require(modules.priceOracle.isSupportedToken(token), "Token not supported");
        require(modules.dutchAuctionManager.getUserTokenAuction(msg.sender, token) == 0, "Collateral in auction");

        // Calculate new position values
        uint256 currentCollateralValue = modules.collateralManager.getTotalCollateralValue(msg.sender);
        uint256 newCollateralValue =
            currentCollateralValue - modules.priceOracle.getTokenValueInUsd(token, withdrawAmount);
        uint256 newDebt = position.debt - burnAmount;

        // Verify final position safety (or complete debt repayment)
        require(newDebt == 0 || _isPositionSafe(newCollateralValue, newDebt), "Unsafe final position");

        // ============ EFFECTS ============
        // Burn stablecoin (internal state change)
        _burn(msg.sender, burnAmount);

        // Ultra-optimized position update with assembly
        assembly {
            let positionSlot := position.slot
            // Update debt (first 128 bits)
            sstore(positionSlot, or(and(sload(positionSlot), not(0xffffffffffffffffffffffffffffffff)), newDebt))
            // Calculate and update risk score
            let riskScore := 0
            if gt(newDebt, 0) { riskScore := and(div(mul(newCollateralValue, 10000), newDebt), 0xffffffff) }
            let newData :=
                or(or(shl(224, timestamp()), shl(192, riskScore)), and(sload(add(positionSlot, 1)), 0xffffffff))
            sstore(add(positionSlot, 1), newData)
        }

        // ============ INTERACTIONS ============
        // Withdraw collateral straight to the user (CollateralManager pays recipient)
        modules.collateralManager.withdraw(msg.sender, token, withdrawAmount, msg.sender);

        emit PositionUpdated(msg.sender, newDebt, newCollateralValue);
    }

    /**
     * @dev Ultra-optimized liquidation function
     */
    function liquidatePosition(address user, address collateralToken, uint256 debtAmount)
        external
        validModules
        nonReentrant
    {
        // ============ CHECKS ============
        UserPosition storage position = positions[user];

        require(user != address(0), "Invalid user");
        require(debtAmount > 0, "Invalid debt amount");
        require(position.debt > 0, "No debt to liquidate");
        require(position.debt >= debtAmount, "Debt amount too high");

        uint256 collateralValue = modules.collateralManager.getTotalCollateralValue(user);
        require(!_isPositionSafe(collateralValue, position.debt), "Position is safe");

        // Calculate liquidation amounts using configured maxLiquidationBonus (basis points)
        uint256 liquidationBonus;
        uint256 totalCollateralNeeded;
        assembly {
            let packed := sload(config.slot)
            let bonusBps := and(shr(160, packed), 0xffffffff)
            liquidationBonus := div(mul(debtAmount, bonusBps), 10000)
            totalCollateralNeeded := add(debtAmount, liquidationBonus)
        }

        // Convert the USD value (debt + bonus, 1e18) into a token amount
        uint256 collateralTokenAmount =
            modules.priceOracle.getTokenAmountFromUsd(collateralToken, totalCollateralNeeded);
        require(
            modules.collateralManager.getUserCollateral(user, collateralToken) >= collateralTokenAmount,
            "Insufficient collateral"
        );
        // Use external self-call so spender is the contract, matching allowance pattern
        require(this.transferFrom(msg.sender, address(this), debtAmount), "Transfer failed");

        // ============ EFFECTS ============
        _burn(address(this), debtAmount);

        // Ultra-optimized position update
        assembly {
            let positionSlot := position.slot
            let newDebt := sub(sload(positionSlot), debtAmount)
            sstore(positionSlot, or(and(sload(positionSlot), not(0xffffffffffffffffffffffffffffffff)), newDebt))

            let riskScore := 0
            if gt(newDebt, 0) {
                riskScore := and(div(mul(sub(collateralValue, totalCollateralNeeded), 10000), newDebt), 0xffffffff)
            }
            sstore(
                add(positionSlot, 1),
                or(or(shl(224, timestamp()), shl(192, riskScore)), and(sload(add(positionSlot, 1)), 0xffffffff))
            )
        }

        // ============ INTERACTIONS ============
        // Seize collateral straight to the liquidator (CollateralManager pays recipient)
        modules.collateralManager.withdraw(user, collateralToken, collateralTokenAmount, msg.sender);

        emit PositionLiquidated(user, msg.sender, debtAmount, collateralTokenAmount);
    }

    // Accept ETH from CollateralManager for withdrawals and liquidations
    // (Single receive function defined at end of file)

    /**
     * @dev Unified liquidation function (auto-selects optimal collateral)
     */
    function liquidate(address user, uint256 debtAmount)
        external
        validModules
        validPosition(user)
        nonReentrant
        rateLimited("LIQUIDATE", debtAmount)
        globalRateLimited("LIQUIDATE", debtAmount)
        returns (uint256 auctionId)
    {
        require(user != address(0), "Invalid user address");
        require(user != msg.sender, "Cannot liquidate self");
        require(debtAmount > 0 && positions[user].debt >= debtAmount, "Invalid debt amount");

        uint256 userCollateralValue = modules.collateralManager.getTotalCollateralValue(user);
        require(!_isPositionSafeForLiquidation(userCollateralValue, positions[user].debt), "Position safe");

        // Find optimal token and start auction
        address optimalToken = modules.liquidationManager.findOptimalTokenForLiquidation(user);
        auctionId = modules.dutchAuctionManager.startDutchAuction(user, optimalToken, debtAmount);

        emit LiquidationTriggered(user, optimalToken, debtAmount, auctionId);
    }

    /**
     * @dev Unified liquidation function (specific token)
     */
    function liquidate(address user, address token, uint256 debtAmount)
        external
        validModules
        validPosition(user)
        nonReentrant
        returns (uint256 auctionId)
    {
        require(user != address(0), "Invalid user address");
        require(token != address(0), "Invalid token address");
        require(user != msg.sender, "Cannot liquidate self");
        require(debtAmount > 0 && positions[user].debt >= debtAmount, "Invalid debt amount");
        require(modules.priceOracle.isSupportedToken(token), "Token not supported");
        require(modules.collateralManager.getUserCollateral(user, token) > 0, "No collateral");

        uint256 userCollateralValue = modules.collateralManager.getTotalCollateralValue(user);
        require(!_isPositionSafeForLiquidation(userCollateralValue, positions[user].debt), "Position safe");

        // Start auction with specific token
        auctionId = modules.dutchAuctionManager.startDutchAuction(user, token, debtAmount);

        emit LiquidationTriggered(user, token, debtAmount, auctionId);
    }

    /**
     * @dev Emergency direct liquidation (owner only). The owner supplies the SGD
     *      being retired so the supply stays backed: transfer in, single debt
     *      decrement, single burn, and equivalent collateral (no bonus) is
     *      seized to the owner.
     */
    function emergencyLiquidate(address user, address token, uint256 debtAmount)
        external
        onlyOwner
        validModules
        validPosition(user)
        nonReentrant
    {
        // ============ CHECKS ============
        UserPosition storage position = positions[user];
        require(debtAmount > 0 && position.debt >= debtAmount, "Invalid debt amount");

        // Owner provides the SGD to retire (spender is the contract itself)
        require(this.transferFrom(msg.sender, address(this), debtAmount), "Transfer failed");

        // ============ EFFECTS ============
        position.debt = uint128(position.debt - debtAmount);
        position.lastUpdate = uint64(block.timestamp);
        _burn(address(this), debtAmount);

        // ============ INTERACTIONS ============
        // Seize equivalent collateral (capped at the user's balance) to the owner
        uint256 collateralAmount = modules.priceOracle.getTokenAmountFromUsd(token, debtAmount);
        uint256 available = modules.collateralManager.getUserCollateral(user, token);
        if (collateralAmount > available) collateralAmount = available;
        if (collateralAmount > 0) {
            modules.collateralManager.withdraw(user, token, collateralAmount, OWNER);
        }

        emit PositionUpdated(user, position.debt, modules.collateralManager.getTotalCollateralValue(user));
    }

    /**
     * @dev Process auction completion (called by DutchAuctionManager). The auction
     *      manager transfers the settled SGD to this contract before calling; the
     *      amount is clamped to the outstanding debt so a rounding residue or a
     *      concurrent partial liquidation can never block settlement.
     */
    function processAuctionCompletion(address user, uint256 debtAmount) external nonReentrant {
        require(msg.sender == address(modules.dutchAuctionManager), "Only auction manager");

        UserPosition storage position = positions[user];
        uint256 settled = debtAmount > position.debt ? position.debt : debtAmount;
        if (settled == 0) return;

        // Update position
        position.debt = uint128(position.debt - settled);
        position.lastUpdate = uint64(block.timestamp);

        // Burn liquidated debt
        _burn(address(this), settled);

        emit PositionUpdated(user, position.debt, modules.collateralManager.getTotalCollateralValue(user));
    }

    // ============================================================================
    // OPTIMIZED VIEW FUNCTIONS WITH CACHING
    // ============================================================================

    // Cache for expensive external calls
    mapping(address => uint256) private _collateralValueCache;
    mapping(address => uint256) private _cacheTimestamp;
    uint256 private constant COLLATERAL_CACHE_DURATION = 300; // 5 minutes

    /**
     * @dev Get user position (ultra-optimized)
     */
    function getUserPosition(address user) external view returns (UserPosition memory) {
        return positions[user];
    }

    /**
     * @dev Get cached collateral value or fetch if expired
     */
    function _getCachedCollateralValue(address user) internal returns (uint256) {
        if (block.timestamp - _cacheTimestamp[user] < COLLATERAL_CACHE_DURATION) {
            return _collateralValueCache[user];
        }
        return modules.collateralManager.getTotalCollateralValue(user);
    }

    function getTotalCollateralValue(address user) external returns (uint256) {
        return modules.collateralManager.getTotalCollateralValue(user);
    }

    function getCollateral(address user, address token) external view returns (uint256) {
        return modules.collateralManager.getUserCollateral(user, token);
    }

    function getDebt(address user) external view returns (uint256) {
        return positions[user].debt;
    }

    /**
     * @dev Calculate required collateral for a given mint amount
     * @param mintAmount Amount of tokens to mint
     * @return Required collateral amount based on minimum collateral ratio
     */
    function getCollateralRequirement(uint256 mintAmount) external view returns (uint256) {
        return (mintAmount * config.minCollateralRatio) / 10000;
    }

    /**
     * @dev Ultra-optimized collateral ratio calculation
     */
    function getCollateralRatio(address user) external view returns (uint256) {
        assembly {
            // Get debt from storage
            mstore(0x00, user)
            mstore(0x20, positions.slot)
            let positionSlot := keccak256(0x00, 0x40)
            let debt := and(sload(positionSlot), 0xffffffffffffffffffffffffffffffff)

            // Return max value if no debt
            if iszero(debt) {
                mstore(0x00, not(0))
                return(0x00, 0x20)
            }

            // Get cached collateral value
            mstore(0x00, user)
            mstore(0x20, _collateralValueCache.slot)
            let cacheSlot := keccak256(0x00, 0x40)
            let collateralValue := sload(cacheSlot)

            // Check cache validity
            mstore(0x20, _cacheTimestamp.slot)
            let timestampSlot := keccak256(0x00, 0x40)
            let cacheTime := sload(timestampSlot)

            // If cache is expired, we'll use it anyway for gas optimization
            // External call would be too expensive here

            // Calculate ratio: (collateralValue * 10000) / debt
            let ratio := div(mul(collateralValue, 10000), debt)
            mstore(0x00, ratio)
            return(0x00, 0x20)
        }
    }

    /**
     * @dev Ultra-fast position safety check
     */
    function isPositionSafe(address user) external returns (bool) {
        uint256 debt;
        assembly {
            mstore(0x00, user)
            mstore(0x20, positions.slot)
            let positionSlot := keccak256(0x00, 0x40)
            debt := sload(positionSlot)
        }
        if (debt == 0) return true;

        uint256 collateralValue = _getCachedCollateralValue(user);
        return _isPositionSafe(collateralValue, debt);
    }

    function isPositionSafeForLiquidation(address user) external returns (bool) {
        UserPosition memory position = positions[user];
        if (position.debt == 0) return true;

        uint256 collateralValue = modules.collateralManager.getTotalCollateralValue(user);
        return _isPositionSafeForLiquidation(collateralValue, position.debt);
    }

    /**
     * @dev Ultra-optimized max mintable calculation
     */
    function getMaxMintable(address user) external view returns (uint256) {
        assembly {
            // Get current debt from storage
            mstore(0x00, user)
            mstore(0x20, positions.slot)
            let positionSlot := keccak256(0x00, 0x40)
            let currentDebt := and(sload(positionSlot), 0xffffffffffffffffffffffffffffffff)

            // Get cached collateral value
            mstore(0x00, user)
            mstore(0x20, _collateralValueCache.slot)
            let cacheSlot := keccak256(0x00, 0x40)
            let collateralValue := sload(cacheSlot)

            // Get min collateral ratio from config
            let configSlot := config.slot
            let minCollateralRatio := and(sload(configSlot), 0xffffffffffffffff)

            // Calculate max debt: (collateralValue * 10000) / minCollateralRatio
            let maxDebt := div(mul(collateralValue, 10000), minCollateralRatio)

            // Calculate max mintable: maxDebt - currentDebt (if positive)
            let result := 0
            if gt(maxDebt, currentDebt) { result := sub(maxDebt, currentDebt) }

            mstore(0x00, result)
            return(0x00, 0x20)
        }
    }

    /**
     * @dev Fast liquidation threshold calculation
     */
    function getLiquidationThreshold(address user) external view returns (uint256) {
        // Plain Solidity on purpose: the previous assembly read config.slot + 1,
        // which is the priceOracle address, not the packed liquidationThreshold.
        uint256 debt = positions[user].debt;
        if (debt == 0) return 0;
        return (debt * config.liquidationThreshold) / Constants.BASIS_POINTS;
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return modules.collateralManager.getUserTokens(user);
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return modules.priceOracle.getSupportedTokens();
    }

    function getTokenPrice(address token) external returns (uint256) {
        return modules.priceOracle.getTokenPrice(token);
    }

    function isSupportedToken(address token) external view returns (bool) {
        return modules.priceOracle.isSupportedToken(token);
    }

    function getSystemConfig() external view returns (PackedConfig memory) {
        return config;
    }

    function getModules() external view returns (PackedModules memory) {
        return modules;
    }

    // ============================================================================
    // ULTRA-OPTIMIZED INTERNAL FUNCTIONS
    // ============================================================================

    /**
     * @dev Ultra-fast position safety check
     */
    function _isPositionSafe(uint256 collateralValue, uint256 debtAmount) internal view returns (bool) {
        if (debtAmount == 0) {
            return true;
        }

        uint256 ratio = (collateralValue * Constants.BASIS_POINTS) / debtAmount;
        return ratio >= config.minCollateralRatio;
    }

    function _isPositionSafeForLiquidation(uint256 collateralValue, uint256 debtAmount) internal view returns (bool) {
        if (debtAmount == 0) return true;
        return (collateralValue * Constants.BASIS_POINTS) >= (debtAmount * config.liquidationThreshold);
    }

    /**
     * @dev Ultra-optimized risk score calculation
     */
    function _calculateRiskScore(uint256 collateralValue, uint256 debtAmount) internal view returns (uint256) {
        assembly {
            if iszero(debtAmount) {
                mstore(0x00, 0)
                return(0x00, 0x20)
            }

            let ratio := div(mul(collateralValue, 10000), debtAmount)
            let configSlot := config.slot
            let minCollateralRatio := sload(configSlot)

            // Simple risk calculation: higher ratio = lower risk
            let result := 10 // Default high risk
            if iszero(lt(ratio, 12000)) { result := 1 } // Very safe (>120%)
            if and(lt(ratio, 12000), iszero(lt(ratio, 11500))) { result := 3 } // Safe (115-120%)
            if and(lt(ratio, 11500), iszero(lt(ratio, 11000))) { result := 5 } // Medium (110-115%)
            if and(lt(ratio, 11000), iszero(lt(ratio, 10500))) { result := 8 } // Risky (105-110%)

            mstore(0x00, result)
            return(0x00, 0x20)
        }
    }

    /**
     * @dev Assembly-optimized collateral validation with enhanced security
     */
    function _validateCollateral(address token, uint256 amount) internal {
        assembly {
            // Check for zero address
            if iszero(token) {
                mstore(0x00, 0x7c946ed7) // "Invalid token address"
                revert(0x1c, 0x04)
            }
            // Check for zero amount
            if iszero(amount) {
                mstore(0x00, 0x7c946ed7) // "Invalid amount"
                revert(0x1c, 0x04)
            }
            // Check for amount overflow (max uint128 for gas optimization)
            if gt(amount, 0xffffffffffffffffffffffffffffffff) {
                mstore(0x00, 0x7c946ed7) // "Amount too large"
                revert(0x1c, 0x04)
            }
        }

        require(modules.priceOracle.isSupportedToken(token), "Token not supported");

        uint256 tokenValue = modules.priceOracle.getTokenValueInUsd(token, amount);
        assembly {
            let minValue := 1000 // Minimum collateral value in USD (0.001 USD)
            let maxValue := 0xffffffffffffffffffffffffffffffff // Maximum value to prevent overflow
            if lt(tokenValue, minValue) {
                mstore(0x00, 0x7c946ed7) // "Collateral too small"
                revert(0x1c, 0x04)
            }
            if gt(tokenValue, maxValue) {
                mstore(0x00, 0x7c946ed7) // "Collateral value too large"
                revert(0x1c, 0x04)
            }
        }
    }

    /**
     * @dev Ultra-compact batch position update
     */
    function _batchUpdatePositions(address[] calldata users, uint256[] calldata newDebts) internal {
        assembly {
            let length := users.length
            if iszero(eq(length, newDebts.length)) {
                mstore(0x00, 0x7c946ed7) // "Array length mismatch"
                revert(0x1c, 0x04)
            }

            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                let user := calldataload(add(users.offset, mul(i, 0x20)))
                let newDebt := calldataload(add(newDebts.offset, mul(i, 0x20)))

                mstore(0x00, user)
                mstore(0x20, positions.slot)
                let positionSlot := keccak256(0x00, 0x40)

                sstore(positionSlot, or(and(sload(positionSlot), not(0xffffffffffffffffffffffffffffffff)), newDebt))
                sstore(
                    add(positionSlot, 1),
                    or(shl(224, timestamp()), and(sload(add(positionSlot, 1)), 0xffffffffffffffff))
                )
            }
        }
    }

    // ============ BATCH OPERATIONS ============

    /**
     * @dev Batch deposit and mint for multiple operations (gas-optimized)
     */
    function batchDepositAndMint(
        address[] calldata tokens,
        uint256[] calldata depositAmounts,
        uint256[] calldata mintAmounts
    ) external payable validModules nonReentrant {
        assembly {
            let length := tokens.length
            if or(iszero(eq(length, depositAmounts.length)), iszero(eq(length, mintAmounts.length))) {
                mstore(0x00, 0x7c946ed7) // "Array length mismatch"
                revert(0x1c, 0x04)
            }
        }

        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];
            bool isEth = (token == Constants.ETH_TOKEN);
            uint256 actualDepositAmount = isEth ? msg.value : depositAmounts[i];
            _processDepositAndMint(token, actualDepositAmount, mintAmounts[i], isEth);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Batch burn and withdraw for multiple operations (gas-optimized)
     */
    function batchBurnAndWithdraw(
        address[] calldata tokens,
        uint256[] calldata burnAmounts,
        uint256[] calldata withdrawAmounts
    ) external validModules nonReentrant {
        assembly {
            let length := tokens.length
            if or(iszero(eq(length, burnAmounts.length)), iszero(eq(length, withdrawAmounts.length))) {
                mstore(0x00, 0x7c946ed7) // "Array length mismatch"
                revert(0x1c, 0x04)
            }
        }

        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];
            bool isEth = (token == Constants.ETH_TOKEN);
            _processBurnAndWithdraw(token, burnAmounts[i], withdrawAmounts[i], isEth);

            unchecked {
                ++i;
            }
        }
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Batch update collateral value cache for multiple users (gas-optimized)
     */
    function batchUpdateCollateralCache(address[] calldata users) external {
        assembly {
            let length := users.length
            let cacheSlot := _collateralValueCache.slot
            let timestampSlot := _cacheTimestamp.slot
            let currentTime := timestamp()

            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                let user := calldataload(add(users.offset, mul(i, 0x20)))

                // Calculate storage slots for this user
                mstore(0x00, user)
                mstore(0x20, cacheSlot)
                let userCacheSlot := keccak256(0x00, 0x40)

                mstore(0x20, timestampSlot)
                let userTimestampSlot := keccak256(0x00, 0x40)

                // Store timestamp (value will be updated externally)
                sstore(userTimestampSlot, currentTime)
            }
        }

        // Update actual values (requires external calls)
        for (uint256 i = 0; i < users.length;) {
            address user = users[i];
            uint256 newValue = modules.collateralManager.getTotalCollateralValue(user);
            _collateralValueCache[user] = newValue;

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Update collateral value cache (gas-optimized with security checks)
     */
    function updateCollateralCache(address user) external {
        require(user != address(0), "Invalid user address");

        uint256 newValue = modules.collateralManager.getTotalCollateralValue(user);

        // Prevent cache manipulation with unrealistic values
        require(newValue <= type(uint128).max, "Value too large for cache");

        assembly {
            mstore(0x00, user)
            mstore(0x20, _collateralValueCache.slot)
            let cacheSlot := keccak256(0x00, 0x40)
            sstore(cacheSlot, newValue)

            mstore(0x20, _cacheTimestamp.slot)
            let timestampSlot := keccak256(0x00, 0x40)
            sstore(timestampSlot, timestamp())
        }
    }

    function updateModules(
        address _priceOracle,
        address _collateralManager,
        address _liquidationManager,
        address _dutchAuctionManager,
        address _repegManager
    ) external onlyTimelock {
        require(
            _priceOracle != address(0) && _collateralManager != address(0) && _liquidationManager != address(0)
                && _dutchAuctionManager != address(0) && _repegManager != address(0),
            "Invalid addresses"
        );

        // Ensure modules are not the same address
        require(
            _priceOracle != _collateralManager && _priceOracle != _liquidationManager
                && _priceOracle != _dutchAuctionManager && _priceOracle != _repegManager
                && _collateralManager != _liquidationManager && _collateralManager != _dutchAuctionManager
                && _collateralManager != _repegManager && _liquidationManager != _dutchAuctionManager
                && _liquidationManager != _repegManager && _dutchAuctionManager != _repegManager,
            "Duplicate module addresses"
        );

        modules = PackedModules({
            priceOracle: IPriceOracle(_priceOracle),
            collateralManager: ICollateralManager(_collateralManager),
            liquidationManager: ILiquidationManager(_liquidationManager),
            dutchAuctionManager: IDutchAuctionManager(_dutchAuctionManager),
            repegManager: IRepegManager(_repegManager)
        });

        emit ModulesUpdated(_priceOracle, _collateralManager, _liquidationManager, _dutchAuctionManager, _repegManager);
    }

    function updateConfig(uint64 _minCollateralRatio, uint64 _liquidationThreshold, uint32 _emergencyThreshold)
        external
        onlyTimelock
    {
        require(
            _minCollateralRatio > _liquidationThreshold && _liquidationThreshold > _emergencyThreshold
                && _emergencyThreshold > 10000,
            "Invalid ratios"
        ); // All above 100%

        // Additional safety checks
        require(_minCollateralRatio <= 50000, "Min collateral ratio too high"); // Max 500%
        require(_minCollateralRatio >= 11000, "Min collateral ratio too low"); // Min 110%
        require(_liquidationThreshold >= 10500, "Liquidation threshold too low"); // Min 105%
        require(_emergencyThreshold >= 10100, "Emergency threshold too low"); // Min 101%

        config.minCollateralRatio = _minCollateralRatio;
        config.liquidationThreshold = _liquidationThreshold;
        config.emergencyThreshold = _emergencyThreshold;
    }

    // ============ RATE LIMITING FUNCTIONS ============

    // ============ RATE LIMITING MODIFIERS ============

    modifier rateLimited(string memory operation, uint256 volume) {
        if (!rateLimitingPaused) {
            require(userRateLimits.checkAndConsume(msg.sender, operation, volume), "Rate limit exceeded");
        }
        _;
    }

    modifier globalRateLimited(string memory operation, uint256 volume) {
        if (!rateLimitingPaused) {
            RateLimiter.consumeGlobal(globalRateLimit, operationCounts, operation, volume);
        }
        _;
    }

    // ============ RATE LIMITING VIEW FUNCTIONS ============

    /**
     * @dev Get user rate limit data
     */
    function getUserRateLimit(address user) external view returns (RateLimiter.RateLimitData memory) {
        return userRateLimits[user];
    }

    /**
     * @dev Get global rate limit data
     */
    function getGlobalRateLimit() external view returns (RateLimiter.GlobalRateLimit memory) {
        return globalRateLimit;
    }

    /**
     * @dev Get operation count for specific operation type
     */
    function getOperationCount(string memory operation) external view returns (uint256) {
        return operationCounts[keccak256(bytes(operation))];
    }

    /**
     * @dev Check if user can perform operation
     */
    function checkRateLimitStatus(
        address user,
        string memory,
        /* operation */
        uint256 volume
    )
        external
        view
        returns (bool)
    {
        if (rateLimitingPaused) return true;
        return userRateLimits.status(user, volume);
    }

    // ============ RATE LIMITING ADMIN FUNCTIONS ============

    /**
     * @dev Set rate limiting pause state (owner only)
     * @param paused Whether to pause rate limiting
     */
    function setRateLimitingPause(bool paused) external onlyOwner {
        rateLimitingPaused = paused;
        emit RateLimitingPauseChanged(paused, msg.sender);
    }

    /**
     * @dev Reset user rate limit (owner only)
     * @param user User address to reset
     */
    function resetUserRateLimit(address user) external onlyOwner {
        delete userRateLimits[user];
    }

    /**
     * @dev Reset global rate limit (owner only)
     */
    function resetGlobalRateLimit() external onlyOwner {
        delete globalRateLimit;
    }

    // ============ REPEG MANAGEMENT FUNCTIONS ============

    /**
     * @dev Trigger automatic repeg check and execution
     * @return triggered Whether repeg was triggered
     * @return newPrice New price after repeg
     */
    function triggerRepeg() external validModules nonReentrant returns (bool triggered, uint128 newPrice) {
        (, uint128 deviation) = modules.repegManager.isRepegNeeded();
        uint128 incentive = modules.repegManager.calculateIncentive(msg.sender);

        emit RepegMonitoring(msg.sender, 1, deviation, incentive, block.timestamp);

        // The caller is forwarded so the incentive reaches them, not this contract
        return modules.repegManager.checkAndTriggerRepeg(msg.sender);
    }

    /**
     * @dev Check if repeg is needed without executing
     * @return needed Whether repeg is needed
     * @return deviation Current price deviation
     */
    function checkRepegStatus() external validModules returns (bool needed, uint128 deviation) {
        (needed, deviation) = modules.repegManager.isRepegNeeded();
        uint128 incentive = modules.repegManager.calculateIncentive(msg.sender);

        emit RepegMonitoring(msg.sender, 0, deviation, incentive, block.timestamp);

        return (needed, deviation);
    }

    /**
     * @dev Get current repeg configuration
     * @return repegConfig Current repeg configuration
     */
    function getRepegConfig() external view validModules returns (IRepegManager.RepegConfig memory repegConfig) {
        return modules.repegManager.getRepegConfig();
    }

    /**
     * @dev Get current repeg state
     * @return state Current repeg state
     */
    function getRepegState() external view validModules returns (IRepegManager.RepegState memory state) {
        return modules.repegManager.getRepegState();
    }

    /**
     * @dev Update repeg configuration (via Timelock)
     * @param newConfig New repeg configuration
     */
    function updateRepegConfig(IRepegManager.RepegConfig calldata newConfig) external onlyTimelock validModules {
        modules.repegManager.updateRepegConfig(newConfig);

        emit RepegConfigUpdated(msg.sender, newConfig.deviationThreshold, newConfig.incentiveRate, false);
    }

    /**
     * @dev Set emergency pause for repeg mechanism (owner only)
     * @param paused Whether to pause repeg operations
     */
    function setRepegEmergencyPause(bool paused) external onlyOwner validModules {
        modules.repegManager.setEmergencyPause(paused);

        IRepegManager.RepegConfig memory repegConfig = modules.repegManager.getRepegConfig();
        emit RepegConfigUpdated(msg.sender, repegConfig.deviationThreshold, repegConfig.incentiveRate, paused);
    }

    /**
     * @dev Get available arbitrage opportunities
     * @return opportunities Array of available arbitrage opportunities
     */
    function getArbitrageOpportunities()
        external
        validModules
        returns (IRepegManager.ArbitrageOpportunity[] memory opportunities)
    {
        return modules.repegManager.getArbitrageOpportunities();
    }

    /**
     * @dev Execute arbitrage opportunity
     * @param amount Amount to use for arbitrage
     * @param maxSlippage Maximum acceptable slippage
     * @return profit Profit from arbitrage
     */
    function executeArbitrage(uint256 amount, uint128 maxSlippage)
        external
        payable
        validModules
        nonReentrant
        returns (uint128 profit)
    {
        (, uint128 deviation) = modules.repegManager.isRepegNeeded();

        emit RepegMonitoring(msg.sender, 2, deviation, uint128(amount), block.timestamp);

        return modules.repegManager.executeArbitrage{value: msg.value}(amount, maxSlippage);
    }

    // NOTE: liquidity is provided/withdrawn directly on the RepegManager so the
    // provider is credited correctly; forwarding through this contract would
    // credit the liquidity to StableGuard instead of the user.

    /**
     * @dev Get liquidity pool status
     * @return totalLiquidity Total liquidity in pool
     * @return availableLiquidity Available liquidity for operations
     */
    function getRepegLiquidityStatus()
        external
        view
        validModules
        returns (uint256 totalLiquidity, uint256 availableLiquidity)
    {
        return modules.repegManager.getLiquidityPoolStatus();
    }

    /**
     * @dev Calculate potential incentive for triggering repeg
     * @param caller Address of potential caller
     * @return incentive Potential incentive amount
     */
    function calculateRepegIncentive(address caller) external validModules returns (uint128 incentive) {
        return modules.repegManager.calculateIncentive(caller);
    }

    // ============ RECEIVE FUNCTION ============

    receive() external payable {
        // Allow contract to receive ETH
    }

    // ============ RATE LIMITING FUNCTIONS ============
}
