// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Secure Lending App with Oracle Integration
 * @author Lexy Samuel
 * @notice Collateral-based lending system with fixed interest and Chainlink price feeds
 * @dev Implements loan-to-value (LTV) checks, liquidation, and interest rate management
 */
contract Lending is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==============================================
    // Events
    // ==============================================
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 totalRepayment);
    event Repaid(address indexed user, uint256 amount);
    event CollateralTokenAdded(address indexed token, address priceFeed);
    event CollateralTokenRemoved(address indexed token);
    event InterestRateChanged(uint256 newRate);
    event Liquidated(address indexed user, address indexed token, uint256 debtCovered, uint256 collateralSeized);
    event DebtResetted(address indexed user);
    event PriceFeedUpdated(address indexed token, address newPriceFeed);

    // ==============================================
    // Errors
    // ==============================================
    /// @notice Thrown when an amount is zero or lower
    error Lending__MustBeMoreThanZero();
    /// @notice Thrown when an amount exceeds allowed limits
    error Lending__AmountExceeds();
    /// @notice Thrown when contract has insufficient fund to lend
    error Lending___InsufficientFunds();
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
    /// @notice Thrown when position is not liquidatable (health factor >= 1)
    error Lending__NotLiquidatable();
    /// @notice Thrown when liquidation deadline has passed
    error Lending__Expired();
    /// @notice Trhown when price calculation returns overflow value
    error Lending__PriceScalingOverflow();

    // ==============================================
    // Constants
    // ==============================================
    uint256 private constant LTV = 75; // 75% LTV ratio
    uint256 private constant MAX_COLLATERAL_TOKENS = 50;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_STALE_TIME = 86400; // 24 hours
    uint256 public constant CLOSE_FACTOR = 0.5e18; // 50% of debt can be liquidated at once
    uint256 public constant LIQUIDATION_BONUS = 1.1e18; // 10% liquidation bonus
    uint256 private constant PRICE_PRECISION = 1e18; // Used for inverse price calculations

    // ==============================================
    // State Variables
    // ==============================================
    IERC20 private immutable i_debtToken;
    uint256 private s_interestRate;
    address[] private s_collateralToken;
    mapping(address => bool) private s_isCollateralSupported;
    mapping(address => uint8) private s_tokenDecimals;
    /// @dev currently no use case
    mapping(address => uint8) private s_priceFeedTokenDecimals;
    mapping(address => AggregatorV3Interface) private s_priceFeeds;
    mapping(address => mapping(address => uint256)) private s_collateralDeposited;
    mapping(address => uint256) private s_totalRepayment;
    mapping(address => uint256) private s_repaid;

    constructor(address initialOwner, address _debtToken) Ownable(initialOwner) {
        i_debtToken = IERC20(_debtToken);
    }

    // ==============================================
    // Main Functions
    // ==============================================

    /**
     * @notice Deposit collateral tokens to secure a loan
     * @param token The address of the collateral token to deposit
     * @param amount The amount of tokens to deposit
     * @dev The token must be supported as collateral and amount must be > 0
     */
    function depositCollateral(address token, uint256 amount) external whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        s_collateralDeposited[msg.sender][token] += amount;

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /**
     * @notice Borrow debt tokens against deposited collateral
     * @param borrowAmount The amount of debt tokens to borrow
     * @dev The borrow amount must be within the LTV ratio of collateral value
     */
    function borrow(uint256 borrowAmount) external whenNotPaused {
        if (borrowAmount <= 0) revert Lending__MustBeMoreThanZero();
        if (borrowAmount > i_debtToken.balanceOf(address(this))) revert Lending___InsufficientFunds();
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
     * @notice Repay borrowed debt tokens
     * @param amount The amount of debt tokens to repay
     * @dev Resets debt if full amount is repaid
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
     * @notice Withdraw deposited collateral tokens
     * @param token The address of the collateral token to withdraw
     * @param amount The amount of tokens to withdraw
     * @dev Requires no outstanding debt and maintains LTV ratio
     */
    function withdrawCollateral(address token, uint256 amount) external whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();
        if (amount > s_collateralDeposited[msg.sender][token]) revert Lending__InsufficientCollateral();
        if (getRemainingDebt(msg.sender) > 0) revert Lending__DebtNotZero();

        s_collateralDeposited[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        if (_calculateHealthFactor(msg.sender) < 1e18) revert Lending__ViolatingLTV();

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @param user The address of the borrower to liquidate
     * @param collateralToken The collateral token to seize
     * @param debtToCover The amount of debt to cover
     * @param minCollateralReceived Minimum collateral to receive (slippage protection)
     * @param deadline Deadline for the liquidation transaction
     * @dev Only liquidates positions below health factor threshold
     */
    // function liquidate(
    //     address user,
    //     address collateralToken,
    //     uint256 debtToCover,
    //     uint256 minCollateralReceived,
    //     uint256 deadline
    // ) external whenNotPaused nonReentrant {
    //     // Parameter validation
    //     if (block.timestamp > deadline) revert Lending__Expired();
    //     if (debtToCover == 0) revert Lending__MustBeMoreThanZero();

    //     // Health factor check
    //     uint256 healthFactor = _calculateHealthFactor(user);
    //     if (healthFactor >= 1e18) revert Lending__NotLiquidatable();

    //     // Load position data
    //     uint256 collateralAmount = s_collateralDeposited[user][collateralToken];
    //     if (collateralAmount == 0) revert Lending__InsufficientCollateral();

    //     // Cache price to avoid multiple calls
    //     uint256 tokenPrice = getTokenPrice(collateralToken);
    //     uint256 collateralValue = (tokenPrice * collateralAmount) / 1e18;
    //     uint256 debtValue = getRemainingDebt(user);

    //     // close factor
    //     uint256 maxCloseableDebt = (debtValue * CLOSE_FACTOR) / 1e18;
    //     debtToCover = debtToCover > maxCloseableDebt ? maxCloseableDebt : debtToCover;
    //     debtToCover = debtToCover > collateralValue ? collateralValue : debtToCover;

    //     // Calculate collateral to seize (with bonus)
    //     uint256 inversePriceWithBonus = (PRICE_PRECISION * LIQUIDATION_BONUS) / tokenPrice;

    //     // Overflow check for inversePriceWithBonus
    //     if (inversePriceWithBonus > type(uint256).max / 1e18) {
    //         revert Lending__PriceScalingOverflow();
    //     }

    //     uint256 collateralToSeize = (debtToCover * inversePriceWithBonus) / 1e18;

    //     // Ensure collateral to seize is within available collateral
    //     if (collateralToSeize > collateralAmount) {
    //         collateralToSeize = collateralAmount;
    //         debtToCover = (collateralToSeize * tokenPrice) / LIQUIDATION_BONUS;
    //     }

    //     // Ensure the minCollateralReceived check
    //     if (collateralToSeize < minCollateralReceived) revert Lending__InsufficientCollateral();

    //     // Update state
    //     s_totalRepayment[user] -= debtToCover;
    //     s_collateralDeposited[user][collateralToken] = collateralAmount - collateralToSeize;

    //     // Execute transfers
    //     IERC20(collateralToken).safeTransfer(msg.sender, collateralToSeize);
    //     i_debtToken.safeTransferFrom(msg.sender, address(this), debtToCover);

    //     emit Liquidated(user, collateralToken, debtToCover, collateralToSeize);
    // }

    // ==============================================
    // Admin Functions
    // ==============================================

    /**
     * @notice Add a new supported collateral token
     * @param token The address of the token to support
     * @param priceFeed The Chainlink price feed for the token
     * @dev Only callable by owner with valid parameters
     */
    function addCollateralToken(address token, address priceFeed) external onlyOwner {
        if (token == address(0)) revert Lending__MustBeMoreThanZero();
        if (priceFeed == address(0)) revert Lending__InvalidPriceFeed();
        if (s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if (s_collateralToken.length >= MAX_COLLATERAL_TOKENS) revert Lending__MaxTokensReached();

        s_collateralToken.push(token);
        s_isCollateralSupported[token] = true;
        s_priceFeeds[token] = AggregatorV3Interface(priceFeed);
        s_priceFeedTokenDecimals[token] = s_priceFeeds[token].decimals();
        s_tokenDecimals[token] = IERC20Metadata(token).decimals();

        emit CollateralTokenAdded(token, priceFeed);
    }

    /**
     * @notice Update the price feed for a collateral token
     * @param token The address of the token to update
     * @param newPriceFeed The new Chainlink price feed address
     * @dev Only callable by owner for supported tokens
     */
    function updatePriceFeed(address token, address newPriceFeed) external onlyOwner {
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if (newPriceFeed == address(0)) revert Lending__InvalidPriceFeed();

        s_priceFeeds[token] = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(token, newPriceFeed);
    }

    /**
     * @notice Remove a collateral token from support
     * @param token The address of the token to remove
     * @dev Only callable by owner for supported tokens
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
     * @notice Set the interest rate for borrowing
     * @param newRate The new interest rate in basis points
     * @dev Only callable by owner, rate must be <= 10000 (100%)
     */
    function setInterestRate(uint256 newRate) external onlyOwner {
        if (newRate > BPS_DENOMINATOR) revert Lending__AmountExceeds();
        s_interestRate = newRate;
        emit InterestRateChanged(newRate);
    }

    /**
     * @notice Pause all borrowing and collateral operations
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause all borrowing and collateral operations
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ==============================================
    // Internal Functions
    // ==============================================

    /**
     * @notice Reset a user's debt to zero
     * @param user The address of the user to reset
     * @dev Emits DebtResetted event
     */
    function _resetDebt(address user) private {
        s_totalRepayment[user] = 0;
        s_repaid[user] = 0;
        emit DebtResetted(user);
    }

    /**
     * @notice Calculate the health factor of a position
     * @param user The address of the user to check
     * @return The health factor as 18 decimal fixed point number
     */
    function _calculateHealthFactor(address user) internal view returns (uint256) {
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 debtValue = getRemainingDebt(user);

        if (debtValue == 0) return type(uint256).max;

        return (collateralValue * LTV) / (debtValue * 100);
    }

    // ==============================================
    // View Functions
    // ==============================================

    /**
     * @notice Get the current price of a collateral token (normalized to 1e18 decimals precision)
     * @param token The address of the token to query
     * @return price The current price in 18 decimals
     * @dev needed pair configuration
     */
    function getTokenPrice(address token) public view returns (uint256 price) {
        AggregatorV3Interface priceFeed = s_priceFeeds[token];
        (, int256 priceInt,, uint256 updatedAt,) = priceFeed.latestRoundData();

        if (priceInt <= 0) revert Lending__InvalidPriceFeed();
        if (block.timestamp - updatedAt > PRICE_STALE_TIME) revert Lending__StalePriceData();

        /// @dev could use priceFeed.decimals() for runtime check
        uint8 priceFeedDecimals = s_priceFeedTokenDecimals[token];
        price = uint256(priceInt) * PRICE_PRECISION / 10 ** priceFeedDecimals;
    }

    /**
     * @notice Get the total collateral value of a user
     * @param user The address of the user to query
     * @return totalValue The total collateral value in debt token terms
     */
    function getTotalCollateralValue(address user) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address token = s_collateralToken[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount > 0) {
                uint256 price = getTokenPrice(token);
                totalValue += price;
            }
        }
    }

    /**
     * @notice Get the remaining debt of a user
     * @param user The address of the user to query
     * @return The remaining debt amount
     */
    function getRemainingDebt(address user) public view returns (uint256) {
        uint256 totalDebt = s_totalRepayment[user];
        uint256 repaid = s_repaid[user];
        return totalDebt > repaid ? totalDebt - repaid : 0;
    }

    /**
     * @notice Get the list of supported collateral tokens
     * @return Array of token addresses
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralToken;
    }

    /**
     * @notice Get a user's collateral balance for a specific token
     * @param user The address of the user to query
     * @param token The address of the token to query
     * @return The collateral balance amount
     */
    function getCollateralBalance(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /**
     * @notice Get a user's total repayment amount (principal + interest)
     * @param user The address of the user to query
     * @return The total repayment amount
     */
    function getTotalRepayment(address user) external view returns (uint256) {
        return s_totalRepayment[user];
    }

    /**
     * @notice Get a user's repaid amount
     * @param user The address of the user to query
     * @return The repaid amount
     */
    function getRepaidAmount(address user) external view returns (uint256) {
        return s_repaid[user];
    }

    /**
     * @notice Get the current interest rate
     * @return The interest rate in basis points
     */
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Check if a token is supported as collateral
     * @param token The address of the token to check
     * @return True if supported, false otherwise
     */
    function isCollateralSupported(address token) external view returns (bool) {
        return s_isCollateralSupported[token];
    }

    /**
     * @notice Get the price feed address for a token
     * @param token The address of the token to query
     * @return The price feed address
     */
    function getPriceFeed(address token) external view returns (address) {
        return address(s_priceFeeds[token]);
    }
}
