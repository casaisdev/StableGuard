// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Constants} from "./Constants.sol";

/**
 * @title CollateralManager - Gas Optimized & Security Hardened
 * @dev Optimized for gas efficiency while maintaining full functionality and security
 */
contract CollateralManager is ICollateralManager, ReentrancyGuard, Ownable {
    // ============ STRUCTS ============

    struct UserCollateral {
        uint128 amount;
        uint128 lastUpdate;
    }

    struct CollateralType {
        address token;
        address priceFeed;
        uint256 fallbackPrice;
        uint8 decimals;
        bool isActive;
        // Risk parameters (ratios, thresholds, bonus) live in StableGuard's
        // config — the single source of truth — not per collateral type.
    }

    // ============ CONSTANTS ============
    uint256 private constant MAX_UINT128 = type(uint128).max;

    // ============ IMMUTABLES ============
    IPriceOracle public immutable PRICE_ORACLE;

    // ============ STATE VARIABLES ============
    address public stableGuard;
    /// @dev Contracts allowed to move custody (StableGuard, DutchAuctionManager)
    mapping(address => bool) public authorizedManagers;
    mapping(address => mapping(address => UserCollateral)) public collateral;
    mapping(address => address[]) public userTokens;
    mapping(address => CollateralType) public collateralTypes;
    address[] public supportedTokens;

    // ============ MODIFIERS ============
    modifier onlyAuth() {
        if (msg.sender != owner() && msg.sender != stableGuard) revert Unauthorized();
        _;
    }

    modifier onlyStableGuard() {
        if (msg.sender != stableGuard) revert Unauthorized();
        _;
    }

    modifier onlyAuthorizedManager() {
        if (!authorizedManagers[msg.sender]) revert Unauthorized();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0 || amount > MAX_UINT128) revert InvalidAmount();
        _;
    }

    modifier validUser(address user) {
        if (user == address(0)) revert InvalidAddress();
        _;
    }

    // ============ CONSTRUCTOR ============
    constructor(address _priceOracle) Ownable(msg.sender) {
        if (_priceOracle == address(0)) revert InvalidAddress();
        PRICE_ORACLE = IPriceOracle(_priceOracle);
    }

    // ============ EXTERNAL FUNCTIONS ============
    function setStableGuard(address _stableGuard) external onlyAuth {
        if (_stableGuard == address(0)) revert InvalidAddress();
        // StableGuard must always be able to move custody
        if (stableGuard != address(0)) authorizedManagers[stableGuard] = false;
        stableGuard = _stableGuard;
        authorizedManagers[_stableGuard] = true;
    }

    function setAuthorizedManager(address manager, bool authorized) external onlyOwner {
        if (manager == address(0)) revert InvalidAddress();
        authorizedManagers[manager] = authorized;
        emit AuthorizedManagerSet(manager, authorized);
    }

    function addCollateralType(address token, address priceFeed, uint256 fallbackPrice, uint8 decimals)
        external
        override
        onlyAuth
    {
        // CHECKS: Input validation
        if (token == address(0)) revert InvalidAddress();
        if (priceFeed == address(0)) revert InvalidAddress();
        if (fallbackPrice == 0) revert InvalidAmount();

        // Check if token is already supported
        if (collateralTypes[token].isActive) revert InvalidAddress(); // Reusing error for "already exists"

        // EFFECTS: Add collateral type
        collateralTypes[token] = CollateralType({
            token: token, priceFeed: priceFeed, fallbackPrice: fallbackPrice, decimals: decimals, isActive: true
        });

        supportedTokens.push(token);
    }

    function deposit(address user, address token, uint256 amount)
        external
        payable
        override
        onlyStableGuard
        validUser(user)
        validAmount(amount)
        nonReentrant
    {
        // CHECKS: Input validation
        if (!PRICE_ORACLE.isSupportedToken(token)) revert UnsupportedToken();

        // INTERACTIONS: For ETH, enforce msg.value; for ERC20, StableGuard transfers beforehand
        if (token == Constants.ETH_TOKEN) {
            if (msg.value != amount) revert ETHMismatch();
        } else {
            if (msg.value != 0) revert ETHMismatch();
            // If this contract doesn't yet hold the tokens (e.g., direct deposit flows),
            // pull them from the caller to ensure subsequent withdrawals succeed.
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal < amount) {
                bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
                if (!ok) revert TransferFailed();
            }
        }

        // EFFECTS: Update state after receiving funds
        _updateCollateral(user, token, amount, true);
        emit Deposit(user, token, amount);
    }

    function withdraw(address user, address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedManager
        validUser(user)
        validAmount(amount)
        nonReentrant
    {
        // CHECKS: Input validation
        if (recipient == address(0)) revert InvalidAddress();
        UserCollateral storage userCol = collateral[user][token];
        if (userCol.amount < amount) revert InsufficientCollateral();

        // EFFECTS: Update state before external interactions
        _updateCollateral(user, token, amount, false);

        // INTERACTIONS: External transfers at the end
        if (token == Constants.ETH_TOKEN) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(token).transfer(recipient, amount);
            if (!success) revert TransferFailed();
        }

        emit Withdraw(user, token, amount);
    }

    // ============ VIEW FUNCTIONS ============
    function getUserCollateral(address user, address token) external view override returns (uint256) {
        if (user == address(0)) revert InvalidAddress();
        return collateral[user][token].amount;
    }

    function getUserTokens(address user) external view override returns (address[] memory) {
        if (user == address(0)) revert InvalidAddress();
        return userTokens[user];
    }

    function getTotalCollateralValue(address user) external override returns (uint256 totalValue) {
        if (user == address(0)) revert InvalidAddress();
        address[] memory tokens = userTokens[user];
        uint256 length = tokens.length;

        // Optimization: use unchecked loop
        for (uint256 i; i < length;) {
            address token = tokens[i];
            UserCollateral memory userCol = collateral[user][token]; // Cache entire struct

            if (userCol.amount > 0) {
                try PRICE_ORACLE.getTokenValueInUsd(token, userCol.amount) returns (uint256 value) {
                    totalValue += value;
                } catch {
                    // Skip tokens with failed price calls
                }
            }

            unchecked {
                ++i;
            } // Gas saving
        }
    }

    function canLiquidate(address user, uint256 debtValue, uint256 liquidationThreshold)
        external
        override
        returns (bool)
    {
        // CHECKS: Input validation
        if (user == address(0)) revert InvalidAddress();
        if (liquidationThreshold == 0 || liquidationThreshold > 15000) revert InvalidAmount(); // Max 150%

        // Avoid multiplication overflow
        if (debtValue == 0) return false;

        uint256 collateralValue = this.getTotalCollateralValue(user);

        // Overflow protection: divide instead of multiply where possible
        return collateralValue < (debtValue * liquidationThreshold) / 10000;
    }

    // ============ INTERNAL FUNCTIONS ============
    function _updateCollateral(address user, address token, uint256 amount, bool isDeposit) internal {
        UserCollateral storage userCol = collateral[user][token];

        if (isDeposit) {
            if (userCol.amount == 0) {
                userTokens[user].push(token);
            }
            userCol.amount += uint128(amount);
        } else {
            userCol.amount -= uint128(amount);
            if (userCol.amount == 0) {
                _removeUserToken(user, token);
            }
        }

        userCol.lastUpdate = uint128(block.timestamp);
    }

    function _removeUserToken(address user, address token) internal {
        address[] storage tokens = userTokens[user];
        uint256 length = tokens.length;

        for (uint256 i; i < length; ++i) {
            if (tokens[i] == token) {
                tokens[i] = tokens[length - 1];
                tokens.pop();
                break;
            }
        }
    }

    // ============ EMERGENCY FUNCTIONS ============
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        // CHECKS: Robust validations
        if (amount == 0) revert InvalidAmount();

        // Verify available balance
        uint256 availableBalance;
        if (token == Constants.ETH_TOKEN) {
            availableBalance = address(this).balance;
        } else {
            if (token == address(0)) revert InvalidAddress();
            availableBalance = IERC20(token).balanceOf(address(this));
        }

        if (amount > availableBalance) revert InsufficientCollateral();

        // INTERACTIONS: External transfers
        if (token == Constants.ETH_TOKEN) {
            (bool success,) = owner().call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(token).transfer(owner(), amount);
            if (!success) revert TransferFailed();
        }
    }

    receive() external payable {
        if (msg.sender != stableGuard) revert Unauthorized();
    }
}
