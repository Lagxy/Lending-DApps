// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
// import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {PriceFeedLib} from "./PriceFeedLib.sol";

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
    event LoanParamsChanged(uint16 newInterestRate, uint32 newDurationLimit);
    event Liquidated(address indexed user, address indexed token, uint256 collateralSeized);
    event PriceFeedUpdated(address indexed token, address newPriceFeed);
    event RaisingCollateral(address indexed user, address indexed token, uint256 amount, uint16 interestRate);
    event CollateralFunded(address indexed user, address indexed funder, uint256 amount);
    event CollateralRaisingCancelled(address indexed user);
    event CollateralRaisingEnded(address indexed user);
    event CollateralRepayment(address indexed user, address indexed funder, uint256 amount);
    event InterestPaid(address indexed user, address indexed funder, uint256 amount);

    // ==============================================
    // Errors
    // ==============================================
    /// @notice Thrown when catch zero addressess
    error Lending__InvalidAddress();
    /// @notice Thrown when an amount is zero or lower
    error Lending__MustBeMoreThanZero();
    /// @notice Thrown when an amount exceeds allowed limits
    error Lending__AmountExceedsLimit();
    /// @notice Thrown when contract has insufficient fund to lend
    error Lending__InsufficientLiquidity();
    /// @notice Thrown when user has insufficient collateral
    error Lending__InsufficientCollateral();
    /// @notice Thrown when user still has outstanding debt
    error Lending__OutstandingDebt();
    /// @notice Thrown when LTV ratio would be violated
    error Lending__LTVViolation();
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
    error Lending__CollateralRaisingOngoing();
    /// @notice Thrown when trying to fund user that closed to be funded
    error Lending__CollateralRaisingClosed();
    /// @notice Thrown when trying to fund user that already closed their raising
    error Lending__NoActiveCollateralRaising();
    /// @notice Thrown when trying to fund user that already reached their raising amount goals
    error Lending__CollateralRaisingGoalReached();
    /// @notice Thrown when trying to close raising when the raising amount havent reach the goals
    error Lending__CollateralRaisingGoalNotMet();
    /// @notice Thrown when trying to reset collateral raising when still having outstanding collateral debt
    error Lending__UnsettledCollateralDebt();
    /// @notice Thrown when trying to reset collateral raising when still having outstanding interest debt
    error Lending__UnsettledInterestDebt();

    // ==============================================
    // Type Declaration
    // ==============================================

    struct Loan {
        uint256 totalDebt;
        uint256 totalRepaid;
        uint16 interestRateBPS;
        uint32 dueDate;
    }

    struct FunderInfo {
        uint256 amount;
        uint256 reward;
    }

    struct CollateralRaising {
        bool isOpen;
        bool isOngoing;
        uint16 interestRateInBPS;
        address collateralToken;
        uint256 targetCollateral;
        uint256 collateralRaised;
        address[] funders;
        mapping(address => FunderInfo) funderInfo;
    }

    // ==============================================
    // Constants
    // ==============================================
    uint8 public constant MAX_COLLATERAL_TOKENS = 50;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint24 public constant PRICE_STALE_TIME = 24 hours;
    uint16 public constant LTV_BPS = 7000; // 70% LTV ratio in BPS (adjustable before deployment)
    uint16 public constant HEALTH_FACTOR_THRESHOLD_BPS = 10_000; // 100%
    uint16 public constant LIQUIDATION_PENALTY_BPS = 1000; // 10%
    uint256 public constant PRICE_PRECISION = 1e18; // Used for inverse price calculations

    // ==============================================
    // State Variables
    // ==============================================

    IERC20 public immutable i_debtToken;
    AggregatorV3Interface public immutable i_debtTokenPriceFeed;
    // IUniswapV2Router02 public immutable i_uniswapRouter;

    uint32 public s_loanDurationLimit;
    uint16 public s_interestRate;
    address[] public s_collateralTokens;
    mapping(address token => AggregatorV3Interface priceFeed) private s_priceFeeds;

    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => Loan loan) private s_loans;
    mapping(address user => CollateralRaising collateralRaising) private s_collateralRaisings;

    // ==============================================
    // Modifiers
    // ==============================================

    /// @notice modifier for preventing flash loans
    modifier noFlashLoans() {
        require(tx.origin == msg.sender, "Flash loans not allowed");
        _;
    }

    constructor(address initialOwner, address _debtToken, address _debtTokenPriceFeed) Ownable(initialOwner) {
        i_debtToken = IERC20(_debtToken);
        i_debtTokenPriceFeed = AggregatorV3Interface(_debtTokenPriceFeed);
        // i_uniswapRouter = IUniswapV2Router02(_uniswapRouter);

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
        if (!isCollateralSupported(_token)) revert Lending__TokenNotSupported();

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
        if (getUserLoanInfo(msg.sender).totalDebt > 0) revert Lending__OutstandingDebt();

        s_collateralDeposited[msg.sender][_token] -= _amount;
        IERC20(_token).safeTransfer(msg.sender, _amount);

        if (_calculateHealthFactorBPS(msg.sender) < HEALTH_FACTOR_THRESHOLD_BPS) revert Lending__LTVViolation();

        emit CollateralWithdrawn(msg.sender, _token, _amount);
    }

    /**
     * @notice Borrow debt tokens against deposited collateral
     * @param _amount The amount of debt tokens to borrow
     * @dev The borrow amount must be within the LTV ratio of collateral value, emit Borrowed event
     */
    function takeLoan(uint256 _amount) external nonReentrant whenNotPaused noFlashLoans {
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > i_debtToken.balanceOf(address(this))) revert Lending__InsufficientLiquidity();
        if (s_loans[msg.sender].totalDebt > 0) revert Lending__OutstandingDebt();

        uint256 collateralValue = getTotalCollateralValueInDebtToken(msg.sender);
        uint256 maxLoan = (collateralValue * LTV_BPS) / BPS_DENOMINATOR;
        if (_amount > maxLoan) revert Lending__AmountExceedsLimit();

        uint256 interest = (_amount * s_interestRate) / BPS_DENOMINATOR;
        s_loans[msg.sender].totalDebt = _amount + interest;
        s_loans[msg.sender].interestRateBPS = s_interestRate;
        s_loans[msg.sender].dueDate = uint32(block.timestamp + s_loanDurationLimit);
        i_debtToken.safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _amount, s_loans[msg.sender].totalDebt);
    }

    /**
     * @notice Repay borrowed debt tokens
     * @param _amount The amount of debt tokens to repay
     * @dev Resets debt if full amount is repaid, emit Repaid event
     */
    function repayLoan(uint256 _amount) external nonReentrant whenNotPaused noFlashLoans {
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        uint256 remainingDebt = getUserLoanInfo(msg.sender).totalDebt;
        if (_amount > remainingDebt) revert Lending__AmountExceedsLimit();

        i_debtToken.safeTransferFrom(msg.sender, address(this), _amount);
        s_loans[msg.sender].totalRepaid += _amount;

        if (s_loans[msg.sender].totalDebt == s_loans[msg.sender].totalRepaid) {
            _resetDebt(msg.sender);
        }

        emit Repaid(msg.sender, _amount);
    }

    /**
     * @notice Raise collateral token from community in returns for interest in form of debt token
     * @param _token The address of collateral token to raise
     * @param _goals The amount of collateral token to raise
     * @param _interestRateBPS The amount of interest rate promised in BPS
     * @dev emit RaisingCollateral event
     */
    function startCollateralRaising(address _token, uint256 _goals, uint16 _interestRateBPS)
        external
        whenNotPaused
        noFlashLoans
    {
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (!isCollateralSupported(_token)) revert Lending__TokenNotSupported();
        if (_goals <= 0) revert Lending__MustBeMoreThanZero();
        if (s_collateralRaisings[msg.sender].isOngoing) revert Lending__CollateralRaisingOngoing();

        s_collateralRaisings[msg.sender].isOpen = true;
        s_collateralRaisings[msg.sender].isOngoing = true;
        s_collateralRaisings[msg.sender].interestRateInBPS = _interestRateBPS;
        s_collateralRaisings[msg.sender].collateralToken = _token;
        s_collateralRaisings[msg.sender].targetCollateral = _goals;

        emit RaisingCollateral(msg.sender, _token, _goals, _interestRateBPS);
    }

    /**
     * @notice Fund user that currently raising collateral
     * @param _user The address of user that raising collateral
     * @param _amount The amount of collateral token to fund the user
     * @dev emit CollateralFunded event
     */
    function fundUser(address _user, uint256 _amount) external nonReentrant whenNotPaused {
        CollateralRaising storage raising = s_collateralRaisings[_user];

        if (_user == address(0)) revert Lending__InvalidAddress();
        if (!raising.isOpen) revert Lending__CollateralRaisingClosed();
        if (!raising.isOngoing) revert Lending__NoActiveCollateralRaising();
        if (raising.targetCollateral == raising.collateralRaised) revert Lending__CollateralRaisingGoalReached();
        if (_amount > (raising.targetCollateral - raising.collateralRaised)) revert Lending__AmountExceedsLimit();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        s_collateralRaisings[_user].collateralRaised += _amount;
        if (raising.funderInfo[msg.sender].amount == 0) {
            s_collateralRaisings[_user].funders.push(msg.sender);
        }
        s_collateralRaisings[_user].funderInfo[msg.sender].amount += _amount;
        IERC20(s_collateralRaisings[_user].collateralToken).safeTransferFrom(msg.sender, address(this), _amount);

        if (s_collateralRaisings[_user].collateralRaised >= s_collateralRaisings[_user].targetCollateral) {
            _endCollateralRaising(_user);
        }

        emit CollateralFunded(_user, msg.sender, _amount);
    }

    /**
     * @notice Cancel active raising and refund all the fund to funder
     */
    function cancelCollateralRaising() external nonReentrant whenNotPaused {
        CollateralRaising storage raising = s_collateralRaisings[msg.sender];

        if (!raising.isOpen) revert Lending__CollateralRaisingClosed();
        if (!raising.isOngoing) revert Lending__NoActiveCollateralRaising();

        // Refund all collected funds to funders
        address[] memory funders = s_collateralRaisings[msg.sender].funders;
        address collateralToken = s_collateralRaisings[msg.sender].collateralToken;
        for (uint256 i = 0; i < funders.length; i++) {
            address funder = funders[i];
            uint256 amount = s_collateralRaisings[msg.sender].funderInfo[funder].amount;
            if (amount > 0) {
                s_collateralDeposited[funder][collateralToken] += amount;
                s_collateralRaisings[msg.sender].funderInfo[funder].amount = 0;
            }
        }

        _resetCollateralRaising(msg.sender);

        emit CollateralRaisingCancelled(msg.sender);
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
     * @param _funder The address of funder to pay to
     * @param _amount The amount of collateral you want to repay
     * @dev Emit CollateralRepayment event
     */
    function repayFunderCollateral(address _funder, uint256 _amount) external nonReentrant whenNotPaused {
        CollateralRaising storage raising = s_collateralRaisings[msg.sender];
        if (_funder == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > raising.funderInfo[_funder].amount) revert Lending__AmountExceedsLimit();
        // may need to check if funder is in array funder

        IERC20(raising.collateralToken).safeTransferFrom(msg.sender, _funder, _amount);
        s_collateralRaisings[msg.sender].funderInfo[_funder].amount -= _amount;

        emit CollateralRepayment(msg.sender, _funder, _amount);
    }

    /**
     * @notice Pay interest to funder
     * @param _funder The address of funder to pay to
     * @param _amount The amount of interest debt you want to pay
     * @dev Emit InterestPaid event
     */
    function payFunderInterest(address _funder, uint256 _amount) external nonReentrant whenNotPaused {
        if (_funder == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > s_collateralRaisings[msg.sender].funderInfo[_funder].reward) revert Lending__AmountExceedsLimit();

        i_debtToken.safeTransferFrom(msg.sender, _funder, _amount);
        s_collateralRaisings[msg.sender].funderInfo[_funder].reward -= _amount;

        emit InterestPaid(msg.sender, _funder, _amount);
    }

    /**
     * @notice Liquidate user at 'underwater' position and swap the token to debtToken
     * @param _user The address of user to liquidate
     * @param _token The address of collateral token to liquidate
     */
    // function liquidate(address _user, address _token) external nonReentrant whenNotPaused noFlashLoans {
    //     if (_user == address(0) || _token == address(0)) revert Lending__InvalidAddress();
    //     if (!isCollateralSupported(_token)) revert Lending__TokenNotSupported();

    //     uint256 healthFactor = _calculateHealthFactorBPS(_user);

    //     Loan storage loan = s_loans[_user];
    //     uint256 totalDebt = loan.totalDebt - loan.totalRepaid;

    //     if (totalDebt == 0) revert Lending__NotLiquidatable();
    //     if (healthFactor >= HEALTH_FACTOR_THRESHOLD_BPS) {
    //         // dueDate bypass healthFactor check
    //         if(loan.dueDate > block.timestamp) revert Lending__NotLiquidatable();
    //     }

    //     uint256 seizeAmount = (totalDebt * (BPS_DENOMINATOR + LIQUIDATION_PENALTY_BPS)) / BPS_DENOMINATOR;
    //     uint256 collateralToSeize = _convertDebtToCollateral(_token, seizeAmount);

    //     uint256 userCollateral = s_collateralDeposited[_user][_token];
    //     if (collateralToSeize > userCollateral) {
    //         collateralToSeize = userCollateral;
    //     }

    //     s_collateralDeposited[_user][_token] -= collateralToSeize;
    //     _resetDebt(_user);

    //     _swapCollateralToDebtToken(_token, collateralToSeize);

    //     emit Liquidated(_user, _token, collateralToSeize);
    // }

    // ==============================================
    // Admin Functions
    // ==============================================

    /**
     * @notice Deposit debt token to the protocol for liquidity
     * @param _amount The amount of token to add
     */
    function depositDebtToken(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert Lending__MustBeMoreThanZero();
        i_debtToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Withdraw debt token from the protocol
     * @param _amount The amount of token to withdraw
     */
    function withdrawDebtToken(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert Lending__MustBeMoreThanZero();
        uint256 balance = i_debtToken.balanceOf(address(this));
        if (_amount > balance) revert Lending__InsufficientLiquidity();

        i_debtToken.safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Add a new supported collateral token
     * @param _token The address of the token to support
     * @param _priceFeed The Chainlink price feed for the token
     * @dev Only callable by owner with valid parameters, emit CollateralTokenAdded event
     */
    function addCollateralToken(address _token, address _priceFeed) external onlyOwner {
        if (_token == address(0) || _priceFeed == address(0)) revert Lending__InvalidAddress();
        if (isCollateralSupported(_token)) revert Lending__TokenAlreadySupported();
        if (s_collateralTokens.length >= MAX_COLLATERAL_TOKENS) revert Lending__MaxTokensReached();

        s_collateralTokens.push(_token);
        s_priceFeeds[_token] = AggregatorV3Interface(_priceFeed);

        emit CollateralTokenAdded(_token, _priceFeed);
    }

    /**
     * @notice Update the price feed for a collateral token
     * @param _token The address of the token to update
     * @param _newPriceFeed The new Chainlink price feed address
     * @dev Only callable by owner for supported tokens, emit PriceFeedUpdated event
     */
    function updatePriceFeed(address _token, address _newPriceFeed) external onlyOwner {
        if (_newPriceFeed == address(0)) revert Lending__InvalidAddress();
        if (!isCollateralSupported(_token)) revert Lending__TokenNotSupported();

        s_priceFeeds[_token] = AggregatorV3Interface(_newPriceFeed);
        emit PriceFeedUpdated(_token, _newPriceFeed);
    }

    /**
     * @notice Remove a collateral token from support
     * @param _token The address of the token to remove
     * @dev Only callable by owner for supported tokens, emit CollateralTokenRemoved event
     */
    function removeCollateralToken(address _token) external onlyOwner {
        if (!isCollateralSupported(_token)) revert Lending__TokenNotSupported();

        uint256 collateralTokenLength = s_collateralTokens.length;
        for (uint256 i = 0; i < collateralTokenLength; i++) {
            if (s_collateralTokens[i] == _token) {
                s_collateralTokens[i] = s_collateralTokens[s_collateralTokens.length - 1];
                s_collateralTokens.pop();
                break;
            }
        }

        emit CollateralTokenRemoved(_token);
    }

    /**
     * @notice Set loan parameter like interest rate and duration limit
     * @param _newRate The new value for interest rate
     * @param _newDuration The new value for duration time limit
     * @dev Emit LoanParamsChanged event
     */
    function setLoanParams(uint16 _newRate, uint32 _newDuration) external onlyOwner {
        if (_newRate > BPS_DENOMINATOR) revert Lending__AmountExceedsLimit();
        s_interestRate = _newRate;
        s_loanDurationLimit = _newDuration;
        emit LoanParamsChanged(_newRate, _newDuration);
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
     * @dev Emits CollateralRaisingEnded event
     */
    function _endCollateralRaising(address _user) internal {
        if (_user == address(0)) revert Lending__InvalidAddress();
        if (!s_collateralRaisings[msg.sender].isOngoing) revert Lending__NoActiveCollateralRaising();
        if (msg.sender != _user) {
            if (s_collateralRaisings[_user].collateralRaised < s_collateralRaisings[_user].targetCollateral) {
                revert Lending__CollateralRaisingGoalNotMet();
            }
        }

        address collateralToken = s_collateralRaisings[_user].collateralToken;
        s_collateralDeposited[_user][collateralToken] += s_collateralRaisings[_user].collateralRaised;

        uint256 tokenPriceInDebtToken = _getTokenPriceInDebtToken(collateralToken);
        uint256 interestRateInBPS = s_collateralRaisings[_user].interestRateInBPS;

        uint256 funderLength = s_collateralRaisings[_user].funders.length;
        for (uint256 i = 0; i < funderLength; i++) {
            address funder = s_collateralRaisings[_user].funders[i];
            uint256 amountFunded = s_collateralRaisings[_user].funderInfo[funder].amount;
            uint256 totalRewardInDebtToken = (amountFunded * tokenPriceInDebtToken) / 1e18;

            s_collateralRaisings[_user].funderInfo[funder].reward =
                (totalRewardInDebtToken * interestRateInBPS) / BPS_DENOMINATOR;
        }

        s_collateralRaisings[_user].isOpen = false;
        emit CollateralRaisingEnded(_user);
    }

    /**
     * @notice Reset a collateral raising detail to zero
     * @param _user The address of the user to reset
     */
    function _resetCollateralRaising(address _user) private {
        if (_user == address(0)) revert Lending__InvalidAddress();

        uint256 funderLength = s_collateralRaisings[_user].funders.length;
        for (uint256 i = 0; i < funderLength; i++) {
            address funder = s_collateralRaisings[_user].funders[i];
            if (s_collateralRaisings[_user].funderInfo[funder].amount > 0) revert Lending__UnsettledCollateralDebt();
            if (s_collateralRaisings[_user].funderInfo[funder].reward > 0) revert Lending__UnsettledInterestDebt();

            delete s_collateralRaisings[_user].funderInfo[funder];
            delete s_collateralRaisings[_user].funderInfo[funder];
        }

        delete s_collateralRaisings[_user];
    }

    /**
     * @notice Reset a user's debt to zero
     * @param _user The address of the user to reset
     */
    function _resetDebt(address _user) private {
        s_loans[_user].totalDebt = 0;
        s_loans[_user].totalRepaid = 0;
        s_loans[_user].dueDate = 0;
        s_loans[_user].interestRateBPS = 0;
    }

    /**
     * @notice Calculate the health factor of a position
     * @param _user The address of the user to check
     * @return The health factor as 18 decimal fixed point number
     */
    function _calculateHealthFactorBPS(address _user) internal view returns (uint256) {
        uint256 collateralValue = getTotalCollateralValueInDebtToken(_user);
        uint256 debtValue = getUserLoanInfo(_user).totalDebt;

        if (debtValue == 0) return type(uint256).max;

        // may need price precision
        return (collateralValue * LTV_BPS) / (debtValue * BPS_DENOMINATOR); // Maintain 18 decimals
    }

    function _getTokenPriceInDebtToken(address _token) internal view returns (uint256) {
        PriceFeedLib.PriceData memory collateral =
            PriceFeedLib.getNormalizedPrice(s_priceFeeds[_token], PRICE_STALE_TIME);
        PriceFeedLib.PriceData memory debt = PriceFeedLib.getNormalizedPrice(i_debtTokenPriceFeed, PRICE_STALE_TIME);
        return PriceFeedLib.convertPrice(collateral, debt);
    }

    /**
     * @notice Swap collateral to debt token
     * @param _token The address of token to swap
     * @param _amount The amount of token to swap
     */
    // function _swapCollateralToDebtToken(address _token, uint256 _amount) internal {
    //     IERC20(_token).forceApprove(address(i_uniswapRouter), _amount);

    //     address[] memory path = new address[](2);
    //     path[0] = _token;
    //     path[1] = address(i_debtToken);

    //     i_uniswapRouter.swapExactTokensForTokens(
    //         _amount,
    //         0, // Minimum amount out
    //         path,
    //         address(this),
    //         block.timestamp + 300
    //     );
    // }

    // ==============================================
    // View Functions
    // ==============================================

    /**
     * @notice Calculate max borrowable debt tokens for a user
     * @param _user The address of User
     * @return maxLoan Max debt tokens allowed (including interest)
     */
    function getMaxLoan(address _user) external view returns (uint256 maxLoan) {
        uint256 collateralValue = getTotalCollateralValueInDebtToken(_user);
        uint256 principal = (collateralValue * LTV_BPS) / BPS_DENOMINATOR;
        return principal + (principal * s_interestRate) / BPS_DENOMINATOR;
    }

    function getTokenPriceInDebtToken(address _token) public view returns (uint256) {
        return _getTokenPriceInDebtToken(_token);
    }

    function getDebtTokenPriceInUsd() public view returns (uint256) {
        PriceFeedLib.PriceData memory debt = PriceFeedLib.getNormalizedPrice(i_debtTokenPriceFeed, PRICE_STALE_TIME);
        return PriceFeedLib.scaleTo18Decimals(debt.value, debt.decimals);
    }

    /**
     * @notice Get the total collateral value of a user in terms
     * @param _user The address of the user to query
     * @return totalValue The total collateral value in debt token terms
     */
    function getTotalCollateralValueInDebtToken(address _user) public view returns (uint256 totalValue) {
        if (_user == address(0)) revert Lending__InvalidAddress();
        uint256 collateralTokenLength = s_collateralTokens.length;

        for (uint256 i = 0; i < collateralTokenLength; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];

            if (amount > 0) {
                uint256 tokenPrice = _getTokenPriceInDebtToken(token);
                totalValue += (amount * tokenPrice) / 1e18;
            }
        }
    }

    /**
     * @notice Get the remaining debt of a user on current loan
     * @param _user The address of the user to query
     * @return The remaining debt amount
     */
    function getLoanRemainingDebt(address _user) external view returns (uint256) {
        uint256 totalDebt = s_loans[_user].totalDebt;
        uint256 repaid = s_loans[_user].totalRepaid;
        return totalDebt > repaid ? totalDebt - repaid : 0;
    }

    /**
     * @notice Get the list of supported collateral tokens
     * @return Array of token addresses
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Get a user's collateral balance for a specific token
     * @param _user The address of the user to query
     * @param _token The address of the token to query
     * @return The collateral balance amount
     */
    function getCollateralBalance(address _user, address _token) public view returns (uint256) {
        return s_collateralDeposited[_user][_token];
    }

    /**
     * @notice get a user loan information
     * @param _user The address of user to query
     */
    function getUserLoanInfo(address _user) public view returns (Loan memory) {
        return s_loans[_user];
    }

    /**
     * @notice Get the user collateral raising detail
     * @param _user the collateral raising detail
     */
    function getCollateralRaisingDetails(address _user)
        external
        view
        returns (
            bool isOpen,
            bool isOngoing,
            address collateralToken,
            uint256 targetCollateral,
            uint256 collateralRaised,
            uint256 interestRateInBPS,
            address[] memory funders,
            FunderInfo[] memory funderInfo
        )
    {
        CollateralRaising storage raising = s_collateralRaisings[_user];
        address[] memory allFunder = raising.funders;

        uint256 funderLength = raising.funders.length;
        FunderInfo[] memory allFunderInfo = new FunderInfo[](funderLength);

        for (uint256 i = 0; i < funderLength; i++) {
            allFunderInfo[i] = raising.funderInfo[allFunder[i]];
        }

        return (
            raising.isOpen,
            raising.isOngoing,
            raising.collateralToken,
            raising.targetCollateral,
            raising.collateralRaised,
            raising.interestRateInBPS,
            allFunder,
            allFunderInfo
        );
    }

    /**
     * @notice Check if a token is supported as collateral
     * @param _token The address of the token to check
     * @return True if supported, false otherwise
     */
    function isCollateralSupported(address _token) public view returns (bool) {
        uint256 collateralTokenLength = s_collateralTokens.length;
        for (uint256 i = 0; i < collateralTokenLength; i++) {
            if (_token == s_collateralTokens[i]) {
                return true;
            }
        }

        return false;
    }
}
