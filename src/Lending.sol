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
        address indexed user, address indexed token, uint256 amount, uint256 interestRate, uint256 raisingDuration
    );
    event FundUser(address indexed user, address indexed funder, uint256 amount);
    event CancelCollateralRaising(address indexed user);
    event EndCollateralRaising(address indexed user);
    event CollateralRaisingResetted(address indexed user);
    event CollateralRepaid(address indexed user, address indexed funder, uint256 amount);
    event InterestPaid(address indexed user, address indexed funder, uint256 amount);

    // ==============================================
    // Errors
    // ==============================================
    /// @notice Thrown when catch zero addressess
    error Lending__InvalidAddress();
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
    /// @notice Thrown when a token is already supported as collateral
    error Lending__TokenAlreadySupported();
    /// @notice Thrown when maximum number of collateral tokens is reached
    error Lending__MaxTokensReached();
    /// @notice Thrown when price data is stale
    error Lending__StalePriceData();
    /// @notice Thrown when position is not liquidatable (health factor >= 1)
    error Lending__NotLiquidatable();
    /// @notice Thrown when any deadline has passed
    error Lending__Expired();
    /// @notice Thrown when price calculation returns overflow value
    error Lending__PriceScalingOverflow();
    /// @notice Thrown when trying to raise collateral when there is collateral raising still going
    error Lending__RaisingIsOngoing();
    /// @notice Thrown when trying to fund user that closed to be funded
    error Lending__RaisingClosed();
    /// @notice Thrown when trying to fund user that already closed their raising
    error Lending__NoOngoingRaising();
    /// @notice Thrown when trying to fund user that already reached their raising amount goals
    error Lending__RaisingAmountReached();
    /// @notice Thrown when trying to close raising when the raising amount havent reach the goals
    error Lending__RaisingAmountNotReached();
    /// @notice Thrown when trying to reset collateral raising when still having outstanding collateral debt
    error Lending__OutstandingCollateralDebt();
    /// @notice Thrown when trying to reset collateral raising when still having outstanding interest debt
    error Lending__OutstandingInterestDebt();

    // ==============================================
    // Type Declaration
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
        address raisedCollateralToken;
        uint256 raisedCollateralAmount;
        uint256 totalCollateralRaised;
        uint256 raisingDuration;
        address[] funder;
        mapping(address funder => uint256 amount) funderToAmountFunded;
        mapping(address funder => uint256 amount) funderToAmountReward;
    }

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

    IERC20 private immutable i_debtToken;
    AggregatorV3Interface private immutable i_debtTokenPriceFeed;

    uint256 private s_loanDurationLimit;
    uint256 private s_interestRate;
    address[] private s_collateralToken;
    mapping(address token => bool isSupported) private s_isCollateralSupported;
    mapping(address token => uint8 decimals) private s_priceFeedTokenDecimals;
    mapping(address token => AggregatorV3Interface priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => Loan loan) private s_userLoan;
    mapping(address user => CollateralRaising collateralRaising) private s_userCollateralRaising;

    constructor(address initialOwner, address _debtToken, address _debtTokenPriceFeed) Ownable(initialOwner) {
        i_debtToken = IERC20(_debtToken);
        i_debtTokenPriceFeed = AggregatorV3Interface(_debtTokenPriceFeed);

        // initial value
        s_loanDurationLimit = 365 days;
        s_interestRate = 200; // 2%
    }

    // ==============================================
    // Main Functions
    // ==============================================

    /**
     * @notice Deposit collateral tokens to secure a loan
     * @param _token The address of the collateral token to deposit
     * @param _amount The amount of tokens to deposit
     * @dev The token must be supported as collateral and amount must be > 0, emit CollateralDeposited event
     */
    function depositCollateral(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (!s_isCollateralSupported[_token]) revert Lending__TokenNotSupported();

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        s_collateralDeposited[msg.sender][_token] += _amount;

        emit CollateralDeposited(msg.sender, _token, _amount);
    }

    /**
     * @notice Withdraw deposited collateral tokens
     * @param _token The address of the collateral token to withdraw
     * @param _amount The amount of tokens to withdraw
     * @dev Requires no outstanding debt and maintains LTV ratio, emit CollateralWithdrawn event
     */
    function withdrawCollateral(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > s_collateralDeposited[msg.sender][_token]) revert Lending__InsufficientCollateral();
        if (getLoanRemainingDebt(msg.sender) > 0) revert Lending__DebtNotZero();

        s_collateralDeposited[msg.sender][_token] -= _amount;
        IERC20(_token).safeTransfer(msg.sender, _amount);

        if (_calculateHealthFactor(msg.sender) < 1e18) revert Lending__ViolatingLTV();

        emit CollateralWithdrawn(msg.sender, _token, _amount);
    }

    /**
     * @notice Borrow debt tokens against deposited collateral
     * @param _amount The amount of debt tokens to borrow
     * @dev The borrow amount must be within the LTV ratio of collateral value, emit Borrowed event
     */
    function borrow(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > i_debtToken.balanceOf(address(this))) revert Lending___InsufficientFunds();
        if (s_userLoan[msg.sender].debtAmount > 0) revert Lending__DebtNotZero();

        uint256 collateralValue = getTotalCollateralValue(msg.sender);
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        if (_amount > maxBorrow) revert Lending__AmountExceeds();

        uint256 interest = (_amount * s_interestRate) / BPS_DENOMINATOR;
        s_userLoan[msg.sender].debtAmount = _amount + interest;
        s_userLoan[msg.sender].interestRateAppliedInBPS = s_interestRate;
        s_userLoan[msg.sender].dueDate = block.timestamp + s_loanDurationLimit;
        i_debtToken.safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _amount, s_userLoan[msg.sender].debtAmount);
    }

    /**
     * @notice Repay borrowed debt tokens
     * @param _amount The amount of debt tokens to repay
     * @dev Resets debt if full amount is repaid, emit Repaid event
     */
    function repay(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        uint256 remainingDebt = getLoanRemainingDebt(msg.sender);
        if (_amount > remainingDebt) revert Lending__AmountExceeds();

        i_debtToken.safeTransferFrom(msg.sender, address(this), _amount);
        s_userLoan[msg.sender].repaidAmount += _amount;

        if (s_userLoan[msg.sender].debtAmount == s_userLoan[msg.sender].repaidAmount) {
            _resetDebt(msg.sender);
        }

        emit Repaid(msg.sender, _amount);
    }

    /**
     * @notice Raise collateral token from community in returns some debt token
     * @param _token The collateral token to raise
     * @param _raiseAmount The amount of collateral token to raise
     * @param _interestRate The amount of interest rate promised
     * @param _raisingDuration The raising duration of the collateral raising
     * @dev emit RaisingCollateral event
     */
    function raiseCollateral(address _token, uint256 _raiseAmount, uint256 _interestRate, uint256 _raisingDuration)
        external
        whenNotPaused
    {
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (!s_isCollateralSupported[_token]) revert Lending__TokenNotSupported();
        if (_raiseAmount <= 0) revert Lending__MustBeMoreThanZero();
        if (_raisingDuration <= 0) revert Lending__MustBeMoreThanZero();
        if (s_userCollateralRaising[msg.sender].ongoing) revert Lending__RaisingIsOngoing();

        s_userCollateralRaising[msg.sender].open = true;
        s_userCollateralRaising[msg.sender].ongoing = true;
        s_userCollateralRaising[msg.sender].raisingDuration = block.timestamp + _raisingDuration;
        s_userCollateralRaising[msg.sender].interestRateInBPS = _interestRate;
        s_userCollateralRaising[msg.sender].raisedCollateralToken = _token;
        s_userCollateralRaising[msg.sender].raisedCollateralAmount = _raiseAmount;

        emit RaisingCollateral(msg.sender, _token, _raiseAmount, _interestRate, _raisingDuration);
    }

    /**
     * @notice Fund user that currently raising collateral
     * @param _user The user that raising collateral
     * @param _amount The amount of collateral token to fund the user
     * @dev emit FundUser event
     */
    function fundUser(address _user, uint256 _amount) external nonReentrant whenNotPaused {
        if (_user == address(0)) revert Lending__InvalidAddress();
        if (!s_userCollateralRaising[_user].open) revert Lending__RaisingClosed();
        if (!s_userCollateralRaising[_user].ongoing) revert Lending__NoOngoingRaising();
        if (s_userCollateralRaising[_user].raisingDuration < block.timestamp) revert Lending__Expired();
        if (
            s_userCollateralRaising[_user].raisedCollateralAmount
                == s_userCollateralRaising[_user].totalCollateralRaised
        ) {
            revert Lending__RaisingAmountReached();
        }
        if (
            _amount
                > (
                    s_userCollateralRaising[_user].raisedCollateralAmount
                        - s_userCollateralRaising[_user].totalCollateralRaised
                )
        ) revert Lending__AmountExceeds();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        s_userCollateralRaising[_user].totalCollateralRaised += _amount;
        if (s_userCollateralRaising[_user].funderToAmountFunded[msg.sender] == 0) {
            s_userCollateralRaising[_user].funder.push(msg.sender);
        }
        s_userCollateralRaising[_user].funderToAmountFunded[msg.sender] += _amount;
        IERC20(s_userCollateralRaising[_user].raisedCollateralToken).safeTransferFrom(
            msg.sender, address(this), _amount
        );

        if (
            s_userCollateralRaising[_user].totalCollateralRaised
                >= s_userCollateralRaising[_user].raisedCollateralAmount
        ) {
            _endCollateralRaising(_user);
        }

        emit FundUser(_user, msg.sender, _amount);
    }

    /**
     * @notice Cancel ongoing raising then refund all the fund to funder
     * @dev emit CancelCollateralRaising event
     */
    function cancelCollateralRaising() external nonReentrant whenNotPaused {
        if (!s_userCollateralRaising[msg.sender].open) revert Lending__RaisingClosed();
        if (!s_userCollateralRaising[msg.sender].ongoing) revert Lending__NoOngoingRaising();

        // Refund all collected funds to funders
        address[] memory funders = s_userCollateralRaising[msg.sender].funder;
        address collateralToken = s_userCollateralRaising[msg.sender].raisedCollateralToken;
        for (uint256 i = 0; i < funders.length; i++) {
            address funder = funders[i];
            uint256 amount = s_userCollateralRaising[msg.sender].funderToAmountFunded[funder];
            if (amount > 0) {
                // instead of the caller pay the gas, letting the funder withdraw their own fund
                s_collateralDeposited[funder][collateralToken] += amount;
                s_userCollateralRaising[msg.sender].funderToAmountFunded[funder] = 0;
            }
        }

        _resetCollateralRaising(msg.sender);

        emit CancelCollateralRaising(msg.sender);
    }

    /**
     * @notice End the current collateral raising period
     * @param _user The user that their raising will be ended
     */
    function endCollateralRaising(address _user) external nonReentrant whenNotPaused {
        _endCollateralRaising(_user);
    }

    /**
     * @notice Repay collateral to funder
     * @param _funder The funder you want to pay to
     * @param _amount The amount of collateral you want to repay
     * @dev Emit CollateralRepaid event
     */
    function repayCollateralToFunder(address _funder, uint256 _amount) external nonReentrant whenNotPaused {
        if (_funder == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > s_userCollateralRaising[msg.sender].funderToAmountFunded[_funder]) {
            revert Lending__AmountExceeds();
        }
        // to check if _funder is on the funder array, need to loop which...

        IERC20(s_userCollateralRaising[msg.sender].raisedCollateralToken).safeTransferFrom(msg.sender, _funder, _amount);
        s_userCollateralRaising[msg.sender].funderToAmountFunded[_funder] -= _amount;

        emit CollateralRepaid(msg.sender, _funder, _amount);
    }

    /**
     * @notice Pay interest to funder
     * @param _funder The funder you want to pay to
     * @param _amount The amount of interest debt you want to pay
     * @dev Emit InterestPaid event
     */
    function payInterestToFunder(address _funder, uint256 _amount) external nonReentrant whenNotPaused {
        if (_funder == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > s_userCollateralRaising[msg.sender].funderToAmountReward[_funder]) {
            revert Lending__AmountExceeds();
        }

        i_debtToken.safeTransferFrom(msg.sender, _funder, _amount);
        s_userCollateralRaising[msg.sender].funderToAmountReward[_funder] -= _amount;

        emit InterestPaid(msg.sender, _funder, _amount);
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
     * @param _token The address of the token to support
     * @param _priceFeed The Chainlink price feed for the token
     * @dev Only callable by owner with valid parameters, emit CollateralTokenAdded event
     */
    function addCollateralToken(address _token, address _priceFeed) external onlyOwner {
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (_priceFeed == address(0)) revert Lending__InvalidAddress();
        if (s_isCollateralSupported[_token]) revert Lending__TokenAlreadySupported();
        if (s_collateralToken.length >= MAX_COLLATERAL_TOKENS) revert Lending__MaxTokensReached();

        s_collateralToken.push(_token);
        s_isCollateralSupported[_token] = true;
        s_priceFeeds[_token] = AggregatorV3Interface(_priceFeed);
        s_priceFeedTokenDecimals[_token] = s_priceFeeds[_token].decimals();

        emit CollateralTokenAdded(_token, _priceFeed);
    }

    /**
     * @notice Update the price feed for a collateral token
     * @param _token The address of the token to update
     * @param _newPriceFeed The new Chainlink price feed address
     * @dev Only callable by owner for supported tokens, emit PriceFeedUpdated event
     */
    function updatePriceFeed(address _token, address _newPriceFeed) external onlyOwner {
        if (!s_isCollateralSupported[_token]) revert Lending__TokenNotSupported();
        if (_newPriceFeed == address(0)) revert Lending__InvalidAddress();

        s_priceFeeds[_token] = AggregatorV3Interface(_newPriceFeed);
        s_priceFeedTokenDecimals[_token] = AggregatorV3Interface(_newPriceFeed).decimals();
        emit PriceFeedUpdated(_token, _newPriceFeed);
    }

    /**
     * @notice Remove a collateral token from support
     * @param _token The address of the token to remove
     * @dev Only callable by owner for supported tokens, emit CollateralTokenRemoved event
     */
    function removeCollateralToken(address _token) external onlyOwner {
        if (!s_isCollateralSupported[_token]) revert Lending__TokenNotSupported();

        uint256 collateralTokenLength = s_collateralToken.length;
        for (uint256 i = 0; i < collateralTokenLength; i++) {
            if (s_collateralToken[i] == _token) {
                s_collateralToken[i] = s_collateralToken[s_collateralToken.length - 1];
                s_collateralToken.pop();
                break;
            }
        }

        s_isCollateralSupported[_token] = false;
        emit CollateralTokenRemoved(_token);
    }

    /**
     * @notice Set the interest rate for borrowing
     * @param _newRate The new interest rate in basis points
     * @dev Only callable by owner, rate must be <= 10000 (100%), Emit LoanDurationLimitChanged event
     */
    function setInterestRate(uint256 _newRate) external onlyOwner {
        if (_newRate > BPS_DENOMINATOR) revert Lending__AmountExceeds();
        s_interestRate = _newRate;
        emit InterestRateChanged(_newRate);
    }

    /**
     * @notice Set the loan raisingDuration limit for borrowing
     * @param _newDuration The new loan raisingDuration limit in seconds
     * @dev Only callable by owner, Emit LoanDurationLimitChanged event
     */
    function setLoanDurationLimit(uint256 _newDuration) external onlyOwner {
        s_loanDurationLimit = _newDuration;
        emit LoanDurationLimitChanged(_newDuration);
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
     * @notice End the current collateral raising period
     * @param _user The user that their raising will be ended
     * @dev Emits EndCollateralRaising event
     */
    function _endCollateralRaising(address _user) internal {
        if (_user == address(0)) revert Lending__InvalidAddress();
        if (!s_userCollateralRaising[msg.sender].ongoing) revert Lending__NoOngoingRaising();

        // if the user is the caller itself, he/she/him can end the raising before the raisingAmount reached or before raising duration ended
        if (msg.sender != _user) {
            if (block.timestamp < s_userCollateralRaising[_user].raisingDuration) revert Lending__RaisingIsOngoing();
            if (
                s_userCollateralRaising[_user].totalCollateralRaised
                    < s_userCollateralRaising[_user].raisedCollateralAmount
            ) revert Lending__RaisingAmountNotReached();
        }

        address raisedCollateralToken = s_userCollateralRaising[_user].raisedCollateralToken;

        // Make the fund able to be used by user
        s_collateralDeposited[_user][raisedCollateralToken] += s_userCollateralRaising[_user].totalCollateralRaised;

        // Calculate interest in debt token user needs to pay later
        uint256 debtTokenPrice = getDebtTokenPriceInUsd(); // debt token price in USD
        uint256 collateralTokenPrice = getTokenPrice(raisedCollateralToken); // collateral token price in USD
        uint256 interestRateInBPS = s_userCollateralRaising[_user].interestRateInBPS; // interest rate in BPS (e.g 500 = 5%)

        // Set how much interest reward each funder get based on total collateral value they fund
        uint256 funderLength = s_userCollateralRaising[_user].funder.length;
        for (uint256 i = 0; i < funderLength; i++) {
            address funder = s_userCollateralRaising[_user].funder[i];
            uint256 amountFunded = s_userCollateralRaising[_user].funderToAmountFunded[funder];
            uint256 amountFundedInUsd = amountFunded * collateralTokenPrice / PRICE_PRECISION;
            uint256 collateralValueInDebtToken = (amountFundedInUsd * PRICE_PRECISION) / debtTokenPrice;

            s_userCollateralRaising[_user].funderToAmountReward[funder] =
                (collateralValueInDebtToken * interestRateInBPS) / BPS_DENOMINATOR;
        }

        s_userCollateralRaising[_user].open = false;

        emit EndCollateralRaising(_user);
    }

    /**
     * @notice Reset a collateral raising detail to zero
     * @param _user The address of the user to reset
     * @dev Emits CollateralRaisingResetted event
     */
    function _resetCollateralRaising(address _user) private {
        if (_user == address(0)) revert Lending__InvalidAddress();

        uint256 funderLength = s_userCollateralRaising[_user].funder.length;
        for (uint256 i = 0; i < funderLength; i++) {
            address funder = s_userCollateralRaising[_user].funder[i];
            if (s_userCollateralRaising[_user].funderToAmountFunded[funder] > 0) {
                revert Lending__OutstandingCollateralDebt();
            }
            if (s_userCollateralRaising[_user].funderToAmountReward[funder] > 0) {
                revert Lending__OutstandingInterestDebt();
            }

            // Resets mapping in one go
            delete s_userCollateralRaising[_user].funderToAmountFunded[funder];
            delete s_userCollateralRaising[_user].funderToAmountReward[funder];
        }

        delete s_userCollateralRaising[_user];

        emit CollateralRaisingResetted(_user);
    }

    /**
     * @notice Reset a user's debt to zero
     * @param _user The address of the user to reset
     * @dev Emits DebtResetted event
     */
    function _resetDebt(address _user) private {
        s_userLoan[_user].debtAmount = 0;
        s_userLoan[_user].repaidAmount = 0;
        s_userLoan[_user].dueDate = 0;
        s_userLoan[_user].interestRateAppliedInBPS = 0;
        emit DebtResetted(_user);
    }

    /**
     * @notice Calculate the health factor of a position
     * @param _user The address of the user to check
     * @return The health factor as 18 decimal fixed point number
     */
    function _calculateHealthFactor(address _user) internal view returns (uint256) {
        uint256 collateralValue = getTotalCollateralValue(_user);
        uint256 debtValue = getLoanRemainingDebt(_user);

        if (debtValue == 0) return type(uint256).max;

        return (collateralValue * LTV * PRICE_PRECISION) / (debtValue * 100); // Maintain 18 decimals
    }

    // ==============================================
    // View Functions
    // ==============================================

    /**
     * @notice Calculate max borrowable debt tokens for a user
     * @param _user User address
     * @return maxBorrow Max debt tokens allowed (including interest)
     */
    function getMaxBorrowable(address _user) external view returns (uint256 maxBorrow) {
        uint256 collateralValue = getTotalCollateralValue(_user);
        uint256 principal = (collateralValue * LTV) / 100;
        return principal + (principal * s_interestRate) / BPS_DENOMINATOR;
    }

    /**
     * @notice Get the current price of a collateral token (normalized to 1e18 decimals precision)
     * @param _token The address of the token to query
     * @return price The current price in 18 decimals
     * @dev needed pair configuration
     */
    function getTokenPrice(address _token) public view returns (uint256 price) {
        AggregatorV3Interface priceFeed = s_priceFeeds[_token];
        (, int256 priceInt,, uint256 updatedAt,) = priceFeed.latestRoundData();

        if (priceInt <= 0) revert Lending__InvalidAddress();
        if (block.timestamp - updatedAt > PRICE_STALE_TIME) revert Lending__StalePriceData();

        /// @dev could use priceFeed.decimals() for runtime check
        uint8 priceFeedDecimals = s_priceFeedTokenDecimals[_token];
        price = uint256(priceInt) * PRICE_PRECISION / 10 ** priceFeedDecimals;
    }

    /**
     * @notice Get the mock price feed for DebtToken/USD (in this case IDRX)
     * @dev Removed time stale check for testing purposes
     */
    function getDebtTokenPriceInUsd() internal view returns (uint256 price) {
        AggregatorV3Interface priceFeed = i_debtTokenPriceFeed;
        (, int256 priceInt,,,) = priceFeed.latestRoundData();

        if (priceInt <= 0) revert Lending__InvalidAddress();

        uint8 priceFeedDecimals = priceFeed.decimals();
        price = uint256(priceInt) * PRICE_PRECISION / 10 ** priceFeedDecimals;
    }

    /**
     * @notice Get the total collateral value of a user
     * @param _user The address of the user to query
     * @return totalValue The total collateral value in debt token terms
     */
    function getTotalCollateralValue(address _user) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address token = s_collateralToken[i];
            uint256 amount = s_collateralDeposited[_user][token];
            if (amount > 0) {
                // assuming priceFeed is normalized to 1e18
                totalValue += (amount * getTokenPrice(token)) / PRICE_PRECISION;
            }
        }
    }

    /**
     * @notice Get USD value of a user's total collateral
     * @param _user User address
     * @return totalValue Total collateral value in USD (1e18 precision)
     */
    function getTotalCollateralValueInUSD(address _user) external view returns (uint256 totalValue) {
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address token = s_collateralToken[i];
            uint256 amount = s_collateralDeposited[_user][token];
            if (amount > 0) {
                // assuming priceFeed is normalized to 1e18
                totalValue += (amount * getTokenPrice(token)) / PRICE_PRECISION;
            }
        }
    }

    /**
     * @notice Get the remaining debt of a user on current loan
     * @param _user The address of the user to query
     * @return The remaining debt amount
     */
    function getLoanRemainingDebt(address _user) public view returns (uint256) {
        uint256 totalDebt = s_userLoan[_user].debtAmount;
        uint256 repaid = s_userLoan[_user].repaidAmount;
        return totalDebt > repaid ? totalDebt - repaid : 0;
    }

    /**
     * @notice Get the interest rate applied of a user current loan
     * @param _user The address of the user to query
     * @return The interest rate applied
     */
    function getLoanInterestRateApplied(address _user) public view returns (uint256) {
        return s_userLoan[_user].interestRateAppliedInBPS;
    }

    /**
     * @notice Get the due date of a user current loan
     * @param _user The address of the user to query
     * @return The due date
     */
    function getLoanDueDate(address _user) public view returns (uint256) {
        return s_userLoan[_user].dueDate;
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
     * @param _user The address of the user to query
     * @param _token The address of the token to query
     * @return The collateral balance amount
     */
    function getCollateralBalance(address _user, address _token) external view returns (uint256) {
        return s_collateralDeposited[_user][_token];
    }

    /**
     * @notice Get a user's total debt amount (principal + interest)
     * @param _user The address of the user to query
     * @return The total repayment amount
     */
    function getLoanDebtAmount(address _user) external view returns (uint256) {
        return s_userLoan[_user].debtAmount;
    }

    /**
     * @notice Get a user's repaid amount
     * @param _user The address of the user to query
     * @return The repaid amount
     */
    function getLoanRepaidAmount(address _user) external view returns (uint256) {
        return s_userLoan[_user].repaidAmount;
    }

    /**
     * @notice Get the current interest rate
     * @return The interest rate in basis points
     */
    function getLoanInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Get the current loan raisingDuration limit
     * @return The loan raisingDuration limit in seconds
     */
    function getLoanDurationLimit() external view returns (uint256) {
        return s_loanDurationLimit;
    }

    function getCollateralRaisingDetails(address _user)
        external
        view
        returns (
            bool open,
            bool ongoing,
            address raisedCollateralToken,
            uint256 raisedCollateralAmount,
            uint256 totalCollateralRaised,
            uint256 raisingDuration,
            uint256 interestRateInBPS
        )
    {
        CollateralRaising storage raising = s_userCollateralRaising[_user];
        return (
            raising.open,
            raising.ongoing,
            raising.raisedCollateralToken,
            raising.raisedCollateralAmount,
            raising.totalCollateralRaised,
            raising.raisingDuration,
            raising.interestRateInBPS
        );
    }

    /**
     * @notice Get time remaining for a collateral raising
     * @param _user Borrower address
     * @return timeLeft Seconds left until deadline (0 if expired)
     */
    function getRaisingTimeLeft(address _user) external view returns (uint256 timeLeft) {
        if (block.timestamp >= s_userCollateralRaising[_user].raisingDuration) {
            return 0;
        }
        return s_userCollateralRaising[_user].raisingDuration - block.timestamp;
    }

    /**
     * @notice Get a funder's contribution and expected reward for a user's raising
     * @param _user The borrower address
     * @param _funder The funder address
     * @return amountFunded Collateral tokens contributed
     * @return rewardDebtTokens Estimated debt token reward
     */
    function getFunderInfo(address _user, address _funder)
        external
        view
        returns (uint256 amountFunded, uint256 rewardDebtTokens)
    {
        return (
            s_userCollateralRaising[_user].funderToAmountFunded[_funder],
            s_userCollateralRaising[_user].funderToAmountReward[_funder]
        );
    }

    /**
     * @notice Get all funders for a user's collateral raising
     * @param _user The borrower address
     * @return Array of funder addresses
     */
    function getCollateralRaisingFunders(address _user) external view returns (address[] memory) {
        return s_userCollateralRaising[_user].funder;
    }

    /**
     * @notice Calculate total debt token interest owed by a user to all funders
     * @param _user Borrower address
     * @return totalInterest Total debt tokens owed as interest
     */
    function getTotalInterestOwed(address _user) external view returns (uint256 totalInterest) {
        address[] storage funders = s_userCollateralRaising[_user].funder;
        for (uint256 i = 0; i < funders.length; i++) {
            totalInterest += s_userCollateralRaising[_user].funderToAmountReward[funders[i]];
        }
    }

    /**
     * @notice Get details of a supported collateral token
     * @param _token The token address
     * @return isSupported Whether the token is supported
     * @return priceFeed The Chainlink price feed address
     * @return currentPrice Current price in USD (1e18)
     */
    function getCollateralTokenInfo(address _token)
        external
        view
        returns (bool isSupported, address priceFeed, uint256 currentPrice)
    {
        return (s_isCollateralSupported[_token], address(s_priceFeeds[_token]), getTokenPrice(_token));
    }

    /**
     * @notice Check if a token is supported as collateral
     * @param _token The address of the token to check
     * @return True if supported, false otherwise
     */
    function isCollateralSupported(address _token) external view returns (bool) {
        return s_isCollateralSupported[_token];
    }

    /**
     * @notice Get the price feed address for a token
     * @param _token The address of the token to query
     * @return The price feed address
     */
    function getPriceFeed(address _token) external view returns (address) {
        return address(s_priceFeeds[_token]);
    }
}
