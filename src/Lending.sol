// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Secure Lending App with Oracle Integration
 * @notice Collateral-based lending system with fixed interest and Chainlink price feeds
 * @dev This contract allows users to deposit collateral, borrow against it, and repay loans.
 * It uses Chainlink oracles for price feeds and implements proper LTV (Loan-to-Value) ratios.
 */
contract Lending is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Errors
    /// @notice Thrown when an amount is zero or less
    error Lending__MustBeMoreThanZero();
    /// @notice Thrown when an amount exceeds allowed limits
    error Lending__AmountExceeds();
    /// @notice Thrown when user has insufficient collateral
    error Lending__InsufficientCollateral();
    /// @notice Thrown when user still has outstanding debt
    error Lending__DebtNotZero();
    /// @notice Thrown when LTV ratio would be violated
    error Lending__ViolatingLTV();
    /// @notice Thrown when a token transfer fails
    error Lending__TransferFailed();
    /// @notice Thrown when a token is not supported as collateral
    error Lending__TokenNotSupported();
    /// @notice Thrown when maximum number of collateral tokens is reached
    error Lending__MaxTokensReached();
    /// @notice Thrown when price data is stale
    error Lending__StalePriceData();
    /// @notice Thrown when an invalid price feed is provided
    error Lending__InvalidPriceFeed();

    // Events
    /// @notice Emitted when collateral is deposited
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when collateral is withdrawn
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when funds are borrowed
    event Borrowed(address indexed user, uint256 amount, uint256 totalRepayment);
    /// @notice Emitted when debt is repaid
    event Repaid(address indexed user, uint256 amount);
    /// @notice Emitted when a new collateral token is added
    event CollateralTokenAdded(address indexed token, address priceFeed);
    /// @notice Emitted when a collateral token is removed
    event CollateralTokenRemoved(address indexed token);
    /// @notice Emitted when interest rate is changed
    event InterestRateChanged(uint256 newRate);
    /// @notice Emitted when a position is liquidated
    event Liquidated(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitted when a user's debt is reset
    event DebtReset(address indexed user);
    /// @notice Emitted when a price feed is updated
    event PriceFeedUpdated(address indexed token, address newPriceFeed);

    // Constants
    uint256 private constant LTV = 75; // 75% LTV ratio
    uint256 private constant MAX_COLLATERAL_TOKENS = 50;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_STALE_TIME = 86400; // 24 hours

    // Immutables
    IERC20 private immutable i_debtToken;

    // State Variables
    uint256 private s_interestRate;
    address[] private s_collateralToken;
    mapping(address => bool) private s_isCollateralSupported;
    mapping(address => uint8) private s_tokenDecimals;
    mapping(address => AggregatorV3Interface) private s_priceFeeds;
    mapping(address => mapping(address => uint256)) private s_collateralDeposited;
    mapping(address => uint256) private s_totalRepayment;
    mapping(address => uint256) private s_repaid;

    /**
     * @notice Initializes the contract with owner and debt token
     * @param initialOwner The address of the contract owner
     * @param _debtToken The address of the ERC20 token used for debt
     */
    constructor(address initialOwner, address _debtToken) Ownable(initialOwner) {
        i_debtToken = IERC20(_debtToken);
    }

    // ==============================================
    // Main External Functions
    // ==============================================

    /**
     * @notice Deposits collateral tokens
     * @dev The token must be supported as collateral
     * @param token The address of the collateral token
     * @param amount The amount of tokens to deposit
     */
    function depositCollateral(address token, uint256 amount) external whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        s_collateralDeposited[msg.sender][token] += amount;

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /**
     * @notice Borrows funds against deposited collateral
     * @dev User must have no existing debt and sufficient collateral
     * @param borrowAmount The amount to borrow
     */
    function borrow(uint256 borrowAmount) external whenNotPaused {
        if (borrowAmount <= 0) revert Lending__MustBeMoreThanZero();
        if (s_totalRepayment[msg.sender] > 0) revert Lending__DebtNotZero();

        uint256 collateralValue = getTotalCollateralValue(msg.sender);
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        if (borrowAmount > maxBorrow) revert Lending__AmountExceeds();

        uint256 interest = (borrowAmount * s_interestRate) / BPS_DENOMINATOR;
        s_totalRepayment[msg.sender] = borrowAmount + interest;
        i_debtToken.safeTransfer(msg.sender, borrowAmount);

        emit Borrowed(msg.sender, borrowAmount, s_totalRepayment[msg.sender]);
    }

    /**
     * @notice Repays borrowed funds
     * @dev If full debt is repaid, the debt is reset
     * @param amount The amount to repay
     */
    function repay(uint256 amount) external whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();

        uint256 remainingDebt = getRemainingDebt(msg.sender);
        if (amount > remainingDebt) revert Lending__AmountExceeds();

        i_debtToken.safeTransferFrom(msg.sender, address(this), amount);
        s_repaid[msg.sender] += amount;

        if (s_repaid[msg.sender] == s_totalRepayment[msg.sender]) {
            _resetDebt(msg.sender);
        }

        emit Repaid(msg.sender, amount);
    }

    /**
     * @notice Withdraws collateral tokens
     * @dev User must have no outstanding debt
     * @param token The address of the collateral token
     * @param amount The amount to withdraw
     */
    function withdrawCollateral(address token, uint256 amount) external whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();
        if (amount > s_collateralDeposited[msg.sender][token]) revert Lending__InsufficientCollateral();
        if (getRemainingDebt(msg.sender) > 0) revert Lending__DebtNotZero();

        s_collateralDeposited[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /**
     * @notice Liquidates a user's position when LTV is violated
     * @dev Can only be called when user's LTV exceeds the allowed ratio
     * @param user The address of the user to liquidate
     * @param collateralToken The collateral token to liquidate
     */
    function liquidate(address user, address collateralToken) external whenNotPaused {
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 maxBorrow = (collateralValue * LTV) / 100;

        if (s_totalRepayment[user] > maxBorrow) {
            uint256 collateralAmount = s_collateralDeposited[user][collateralToken];
            delete s_collateralDeposited[user][collateralToken];
            IERC20(collateralToken).safeTransfer(msg.sender, collateralAmount);

            emit Liquidated(user, collateralToken, collateralAmount);
        } else {
            revert Lending__ViolatingLTV();
        }
    }

    // ==============================================
    // Admin Functions
    // ==============================================

    /**
     * @notice Adds a new collateral token
     * @dev Only callable by owner
     * @param token The address of the token to add
     * @param priceFeed The address of the Chainlink price feed for the token
     */
    function addCollateralToken(address token, address priceFeed) external onlyOwner {
        if (token == address(0)) revert Lending__MustBeMoreThanZero();
        if (priceFeed == address(0)) revert Lending__InvalidPriceFeed();
        if (s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if (s_collateralToken.length >= MAX_COLLATERAL_TOKENS) revert Lending__MaxTokensReached();

        s_collateralToken.push(token);
        s_isCollateralSupported[token] = true;
        s_tokenDecimals[token] = IERC20Metadata(token).decimals();
        s_priceFeeds[token] = AggregatorV3Interface(priceFeed);

        emit CollateralTokenAdded(token, priceFeed);
    }

    /**
     * @notice Updates the price feed for a collateral token
     * @dev Only callable by owner
     * @param token The address of the token
     * @param newPriceFeed The address of the new price feed
     */
    function updatePriceFeed(address token, address newPriceFeed) external onlyOwner {
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if (newPriceFeed == address(0)) revert Lending__InvalidPriceFeed();

        s_priceFeeds[token] = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(token, newPriceFeed);
    }

    /**
     * @notice Removes a collateral token
     * @dev Only callable by owner
     * @param token The address of the token to remove
     */
    function removeCollateralToken(address token) external onlyOwner {
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();

        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            if (s_collateralToken[i] == token) {
                s_collateralToken[i] = s_collateralToken[s_collateralToken.length - 1];
                s_collateralToken.pop();
                break;
            }
        }

        s_isCollateralSupported[token] = false;
        emit CollateralTokenRemoved(token);
    }

    /**
     * @notice Sets the interest rate
     * @dev Only callable by owner. Rate is in basis points (BPS)
     * @param newRate The new interest rate in BPS
     */
    function setInterestRate(uint256 newRate) external onlyOwner {
        if (newRate > BPS_DENOMINATOR) revert Lending__AmountExceeds();
        s_interestRate = newRate;
        emit InterestRateChanged(newRate);
    }

    /**
     * @notice Pauses the contract
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ==============================================
    // Internal Functions
    // ==============================================

    /**
     * @notice Resets a user's debt
     * @param user The address of the user
     */
    function _resetDebt(address user) internal {
        s_totalRepayment[user] = 0;
        s_repaid[user] = 0;
        emit DebtReset(user);
    }

    // ==============================================
    // View Functions
    // ==============================================

    /**
     * @notice Gets the price of a token from its price feed
     * @param token The address of the token
     * @return The price of the token normalized to 18 decimals
     */
    function getTokenPrice(address token) public view returns (uint256) {
        AggregatorV3Interface priceFeed = s_priceFeeds[token];
        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();

        if (price <= 0) revert Lending__InvalidPriceFeed();
        if (block.timestamp - updatedAt > PRICE_STALE_TIME) revert Lending__StalePriceData();

        uint8 priceFeedDecimals = priceFeed.decimals();
        return uint256(price) * (10 ** (18 - priceFeedDecimals));
    }

    /**
     * @notice Calculates the total value of a user's collateral
     * @param user The address of the user
     * @return totalValue The total value of collateral in debt token terms
     */
    function getTotalCollateralValue(address user) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address token = s_collateralToken[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount > 0) {
                uint256 price = getTokenPrice(token);
                uint256 decimals = s_tokenDecimals[token];
                totalValue += (amount * price) / (10 ** decimals);
            }
        }
    }

    /**
     * @notice Gets a user's remaining debt
     * @param user The address of the user
     * @return The remaining debt amount
     */
    function getRemainingDebt(address user) public view returns (uint256) {
        uint256 totalDebt = s_totalRepayment[user];
        uint256 repaid = s_repaid[user];
        return totalDebt > repaid ? totalDebt - repaid : 0;
    }

    /**
     * @notice Gets all supported collateral tokens
     * @return An array of collateral token addresses
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralToken;
    }

    /**
     * @notice Gets a user's collateral balance for a specific token
     * @param user The address of the user
     * @param token The address of the token
     * @return The collateral balance
     */
    function getCollateralBalance(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /**
     * @notice Gets a user's total repayment amount (principal + interest)
     * @param user The address of the user
     * @return The total repayment amount
     */
    function getTotalRepayment(address user) external view returns (uint256) {
        return s_totalRepayment[user];
    }

    /**
     * @notice Gets the amount a user has repaid
     * @param user The address of the user
     * @return The repaid amount
     */
    function getRepaidAmount(address user) external view returns (uint256) {
        return s_repaid[user];
    }

    /**
     * @notice Gets the current interest rate
     * @return The interest rate in basis points (BPS)
     */
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Checks if a token is supported as collateral
     * @param token The address of the token
     * @return True if the token is supported
     */
    function isCollateralSupported(address token) external view returns (bool) {
        return s_isCollateralSupported[token];
    }

    /**
     * @notice Gets the price feed address for a token
     * @param token The address of the token
     * @return The price feed address
     */
    function getPriceFeed(address token) external view returns (address) {
        return address(s_priceFeeds[token]);
    }
}
