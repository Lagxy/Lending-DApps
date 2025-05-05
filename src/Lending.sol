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
 * @notice Collateral-based lending system with fixed interest, collateral raising, and Chainlink price feeds
 * @dev Implements loan-to-value (LTV) checks, liquidation, and interest rate management
 */
contract Lending is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==============================================
    // Events
    // ==============================================
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 totalDebt);
    event Repaid(address indexed user, uint256 amount);
    event CollateralTokenAdded(address indexed token, address priceFeed);
    event CollateralTokenRemoved(address indexed token);
    event InterestRateChanged(uint256 newRate);
    event LoanDurationLimitChanged(uint256 newDuration);
    event Liquidated(address indexed user, address indexed token, uint256 debtCovered, uint256 collateralSeized);
    event DebtResetted(address indexed user);
    event PriceFeedUpdated(address indexed token, address newPriceFeed);
    event RaisingCollateral(
        address indexed user, address indexed token, uint256 amount, uint256 interestRate, uint256 duration
    );
    event FundUser(address indexed user, address indexed funder, uint256 amount);

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
    /// @notice Thrown when price calculation returns overflow value
    error Lending__PriceScalingOverflow();
    /// @notice Thrown when trying to raise collateral when there is collateral raising still going
    error Lending__RaisingIsOngoing();
    /// @notice Thrown when trying to fund user that closed to be funded
    error Lending__RaisingClosed();
    /// @notice Thrown when trying to fund user that already closed their raising
    error Lending__RaisingIsEnded();
    /// @notice Thrown when trying to fund user that already reached their raising amount goals
    error Lending__RaisingAmountReached();

    // ==============================================
    // Constants
    // ==============================================
    uint256 private constant LTV = 75; // 75% LTV ratio (adjustable before deployment)
    uint256 private constant MAX_COLLATERAL_TOKENS = 50;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_STALE_TIME = 24 hours;
    // uint256 public constant CLOSE_FACTOR = 0.5e18; // 50% of debt can be liquidated at once
    // uint256 public constant LIQUIDATION_BONUS = 1.1e18; // 10% liquidation bonus
    uint256 private constant PRICE_PRECISION = 1e18; // Used for inverse price calculations

    // ==============================================
    // State Variables
    // ==============================================
    struct Loan {
        uint256 debtAmount;
        uint256 repaidAmount;
        uint256 interestRateAppliedInBPS;
        uint256 dueDate;
    }

    struct CollateralRaising {
        bool open;
        bool ongoing;
        uint256 interestRateInBPS;
        uint256 totalDebtTokenYield;
        address raisedCollateral;
        uint256 raisedCollateralAmount;
        uint256 totalCollateralRaised;
        uint256 duration;
        address[] funder;
        mapping(address funder => uint256 amount) funderToAmount;
    }

    IERC20 private immutable i_debtToken;
    uint256 private s_loanDurationLimit;
    uint256 private s_interestRate;
    address[] private s_collateralToken;
    mapping(address token => bool isSupported) private s_isCollateralSupported;
    mapping(address token => uint8 decimals) private s_priceFeedTokenDecimals;
    mapping(address token => AggregatorV3Interface priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => Loan loan) private s_userLoan;
    mapping(address user => CollateralRaising collateralRaising) private s_userCollateralRaising;

    constructor(address initialOwner, address _debtToken) Ownable(initialOwner) {
        i_debtToken = IERC20(_debtToken);

        // initial value
        s_loanDurationLimit = 365 days;
        s_interestRate = 200; // 2%
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
    function depositCollateral(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        s_collateralDeposited[msg.sender][token] += amount;

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /**
     * @notice Withdraw deposited collateral tokens
     * @param token The address of the collateral token to withdraw
     * @param amount The amount of tokens to withdraw
     * @dev Requires no outstanding debt and maintains LTV ratio
     */
    function withdrawCollateral(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();
        if (amount > s_collateralDeposited[msg.sender][token]) revert Lending__InsufficientCollateral();
        if (getLoanRemainingDebt(msg.sender) > 0) revert Lending__DebtNotZero();

        s_collateralDeposited[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        if (_calculateHealthFactor(msg.sender) < 1e18) revert Lending__ViolatingLTV();

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    /**
     * @notice Borrow debt tokens against deposited collateral
     * @param borrowAmount The amount of debt tokens to borrow
     * @dev The borrow amount must be within the LTV ratio of collateral value
     */
    function borrow(uint256 borrowAmount) external nonReentrant whenNotPaused {
        if (borrowAmount <= 0) revert Lending__MustBeMoreThanZero();
        if (borrowAmount > i_debtToken.balanceOf(address(this))) revert Lending___InsufficientFunds();
        if (s_userLoan[msg.sender].debtAmount > 0) revert Lending__DebtNotZero();

        uint256 collateralValue = getTotalCollateralValue(msg.sender);
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        if (borrowAmount > maxBorrow) revert Lending__AmountExceeds();

        uint256 interest = (borrowAmount * s_interestRate) / BPS_DENOMINATOR;
        s_userLoan[msg.sender].debtAmount = borrowAmount + interest;
        s_userLoan[msg.sender].interestRateAppliedInBPS = s_interestRate;
        s_userLoan[msg.sender].dueDate = block.timestamp + s_loanDurationLimit;
        i_debtToken.safeTransfer(msg.sender, borrowAmount);

        emit Borrowed(msg.sender, borrowAmount, s_userLoan[msg.sender].debtAmount);
    }

    /**
     * @notice Repay borrowed debt tokens
     * @param amount The amount of debt tokens to repay
     * @dev Resets debt if full amount is repaid
     */
    function repay(uint256 amount) external nonReentrant whenNotPaused {
        if (amount <= 0) revert Lending__MustBeMoreThanZero();

        uint256 remainingDebt = getLoanRemainingDebt(msg.sender);
        if (amount > remainingDebt) revert Lending__AmountExceeds();

        i_debtToken.safeTransferFrom(msg.sender, address(this), amount);
        s_userLoan[msg.sender].repaidAmount += amount;

        if (s_userLoan[msg.sender].debtAmount == s_userLoan[msg.sender].repaidAmount) {
            _resetDebt(msg.sender);
        }

        emit Repaid(msg.sender, amount);
    }

    /**
     * @notice Raise collateral token from community in returns some debt token
     * @param token The collateral token to raise
     * @param raiseAmount The amount of collateral token to raise
     * @param interestRate The amount of interest rate promised
     * @param duration The duration of the collateral raising until payed
     */
    function raiseCollateral(address token, uint256 raiseAmount, uint256 interestRate, uint256 duration)
        external
        whenNotPaused
    {
        if (!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if (raiseAmount <= 0) revert Lending__MustBeMoreThanZero();
        if (s_userCollateralRaising[msg.sender].ongoing) revert Lending__RaisingIsOngoing();

        s_userCollateralRaising[msg.sender].open = true;
        s_userCollateralRaising[msg.sender].ongoing = true;
        s_userCollateralRaising[msg.sender].duration = block.timestamp + duration;
        s_userCollateralRaising[msg.sender].interestRateInBPS = interestRate;
        s_userCollateralRaising[msg.sender].raisedCollateral = token;
        s_userCollateralRaising[msg.sender].raisedCollateralAmount = raiseAmount;

        emit RaisingCollateral(msg.sender, token, raiseAmount, interestRate, duration);
    }

    /**
     * @notice Fund user that currently raising collateral
     * @param user The user that raising collateral
     * @param amount The amount of collateral token to fund the user
     */
    function fundUser(address user, uint256 amount) external nonReentrant whenNotPaused {
        if (!s_userCollateralRaising[user].open) revert Lending__RaisingClosed();
        if (!s_userCollateralRaising[user].ongoing) revert Lending__RaisingIsEnded();
        if (s_userCollateralRaising[user].duration < block.timestamp) revert Lending__RaisingIsEnded();
        if (s_userCollateralRaising[user].raisedCollateralAmount == s_userCollateralRaising[user].totalCollateralRaised)
        {
            revert Lending__RaisingAmountReached();
        }
        if (
            amount
                > (
                    s_userCollateralRaising[user].raisedCollateralAmount
                        - s_userCollateralRaising[user].totalCollateralRaised
                )
        ) revert Lending__AmountExceeds();
        if (amount <= 0) revert Lending__MustBeMoreThanZero();

        s_userCollateralRaising[user].totalCollateralRaised += amount;
        if (s_userCollateralRaising[user].funderToAmount[msg.sender] == 0) {
            s_userCollateralRaising[user].funder.push(msg.sender);
        }
        s_userCollateralRaising[user].funderToAmount[msg.sender] += amount;
        IERC20(s_userCollateralRaising[user].raisedCollateral).safeTransferFrom(msg.sender, address(this), amount);

        // if(s_userCollateralRaising[user].raisedCollateralAmount - s_userCollateralRaising[user].totalCollateralRaised == 0)

        emit FundUser(user, msg.sender, amount);
    }

    function cancelCollateralRaising() external nonReentrant whenNotPaused {}

    function closeCollateralRaising() external nonReentrant whenNotPaused {}

    function repayCollateral() external nonReentrant whenNotPaused {}

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
     * @notice Set the loan duration limit for borrowing
     * @param newDuration The new loan duration limit in seconds
     * @dev Only callable by owner
     */
    function setLoanDurationLimit(uint256 newDuration) external onlyOwner {
        s_loanDurationLimit = newDuration;
        emit LoanDurationLimitChanged(newDuration);
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
        s_userLoan[user].debtAmount = 0;
        s_userLoan[user].repaidAmount = 0;
        s_userLoan[user].dueDate = 0;
        s_userLoan[user].interestRateAppliedInBPS = 0;
        emit DebtResetted(user);
    }

    /**
     * @notice Calculate the health factor of a position
     * @param user The address of the user to check
     * @return The health factor as 18 decimal fixed point number
     */
    function _calculateHealthFactor(address user) internal view returns (uint256) {
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 debtValue = getLoanRemainingDebt(user);

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
                // assuming priceFeed is normalized to 1e18
                totalValue += price;
            }
        }
    }

    /**
     * @notice Get the remaining debt of a user on current loan
     * @param user The address of the user to query
     * @return The remaining debt amount
     */
    function getLoanRemainingDebt(address user) public view returns (uint256) {
        uint256 totalDebt = s_userLoan[user].debtAmount;
        uint256 repaid = s_userLoan[user].repaidAmount;
        return totalDebt > repaid ? totalDebt - repaid : 0;
    }

    /**
     * @notice Get the interest rate applied of a user current loan
     * @param user The address of the user to query
     * @return The interest rate applied
     */
    function getLoanInterestRateApplied(address user) public view returns (uint256) {
        return s_userLoan[user].interestRateAppliedInBPS;
    }

    /**
     * @notice Get the due date of a user current loan
     * @param user The address of the user to query
     * @return The due date
     */
    function getLoanDueDate(address user) public view returns (uint256) {
        return s_userLoan[user].dueDate;
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
     * @notice Get a user's total debt amount (principal + interest)
     * @param user The address of the user to query
     * @return The total repayment amount
     */
    function getLoanDebtAmount(address user) external view returns (uint256) {
        return s_userLoan[user].debtAmount;
    }

    /**
     * @notice Get a user's repaid amount
     * @param user The address of the user to query
     * @return The repaid amount
     */
    function getLoanRepaidAmount(address user) external view returns (uint256) {
        return s_userLoan[user].repaidAmount;
    }

    /**
     * @notice Get the current interest rate
     * @return The interest rate in basis points
     */
    function getLoanInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Get the current loan duration limit
     * @return The loan duration limit in seconds
     */
    function getLoanDurationLimit() external view returns (uint256) {
        return s_loanDurationLimit;
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
