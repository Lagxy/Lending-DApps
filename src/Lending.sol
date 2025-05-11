// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
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
    event CollateralRaisingClosed(address indexed user);
    event CollateralRepayment(address indexed user, address indexed funder, uint256 amount);
    event InterestPaid(address indexed user, address indexed funder, uint256 amount);

    // ==============================================
    // Errors
    // ==============================================
    error Lending__InvalidAddress();
    error Lending__MustBeMoreThanZero();
    error Lending__AmountExceedsLimit();
    error Lending__InsufficientLiquidity();
    error Lending__InsufficientCollateral();
    error Lending__OutstandingDebt();
    error Lending__LTVViolation();
    error Lending__CollateralNotSupported();
    error Lending__TokenAlreadySupported();
    error Lending__NotLiquidatable();
    error Lending__CollateralRaisingAlreadyOpen();
    error Lending__CollateralRaisingAlreadyClosed();
    error Lending__CollateralRaisingTargetReached();
    error Lending__CollateralRaisingTargetNotMet();
    error Lending__UnsettledCollateralDebt();
    error Lending__UnsettledInterestDebt();

    // ==============================================
    // Type Declaration
    // ==============================================

    struct Loan {
        uint256 debt;
        uint256 repaid;
        uint256 dueDate;
    }

    struct FunderInfo {
        uint256 amount;
        uint256 reward;
    }

    struct CollateralRaising {
        bool isOpen;
        address collateralToken;
        uint256 interestRateInBPS;
        uint256 target;
        uint256 raised;
        address[] funders;
        mapping(address => FunderInfo) funderInfo;
    }

    // ==============================================
    // Constants
    // ==============================================
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint24 public constant PRICE_STALE_TIME = 24 hours;
    uint16 public constant LTV_BPS = 7000; // 70% LTV ratio in BPS (adjustable before deployment)
    uint16 public constant HEALTH_FACTOR_THRESHOLD_BPS = 10_000; // 100%
    uint16 public constant LIQUIDATION_PENALTY_BPS = 1000; // 10%
    uint64 public constant PRICE_PRECISION = 1e18; // Used for inverse price calculations

    // ==============================================
    // State Variables
    // ==============================================

    address public immutable i_debtToken;
    address public immutable i_debtTokenPriceFeed;
    address public immutable i_uniswapRouter;

    uint32 public s_loanDurationLimit;
    uint16 public s_interestRateInBPS;
    address[] public s_collateralTokens;
    mapping(address token => address priceFeed) private s_priceFeeds;

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

    constructor(address initialOwner, address _debtToken, address _debtTokenPriceFeed, address _uniswapRouter)
        Ownable(initialOwner)
    {
        i_debtToken = _debtToken;
        i_debtTokenPriceFeed = _debtTokenPriceFeed;
        i_uniswapRouter = _uniswapRouter;

        // initial value
        s_loanDurationLimit = 365 days;
        s_interestRateInBPS = 200; // 2%
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
        if (s_priceFeeds[_token] == address(0)) revert Lending__CollateralNotSupported();

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
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (_amount > getCollateralBalance(_token)) revert Lending__InsufficientCollateral();
        if (getUserLoanInfo(msg.sender).debt > 0) revert Lending__OutstandingDebt();
        if (_calculateHealthFactorBPS(msg.sender) < HEALTH_FACTOR_THRESHOLD_BPS) revert Lending__LTVViolation();

        s_collateralDeposited[msg.sender][_token] -= _amount;
        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit CollateralWithdrawn(msg.sender, _token, _amount);
    }

    /**
     * @notice Borrow debt tokens against deposited collateral
     * @param _amount The amount of debt tokens to borrow
     * @dev The borrow amount must be within the LTV ratio of collateral value, emit Borrowed event
     */
    function takeLoan(uint256 _amount) external nonReentrant whenNotPaused noFlashLoans {
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > IERC20(i_debtToken).balanceOf(address(this))) revert Lending__InsufficientLiquidity();
        if (getUserLoanInfo(msg.sender).debt > 0) revert Lending__OutstandingDebt();

        uint256 collateralValue = getTotalCollateralValueInDebtToken(msg.sender);
        uint256 maxLoan = (collateralValue * LTV_BPS) / BPS_DENOMINATOR;
        if (_amount > maxLoan) revert Lending__AmountExceedsLimit();

        uint256 interest = (_amount * s_interestRateInBPS) / BPS_DENOMINATOR;
        s_loans[msg.sender].debt = _amount + interest;
        s_loans[msg.sender].dueDate = uint32(block.timestamp + s_loanDurationLimit);
        IERC20(i_debtToken).safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _amount, s_loans[msg.sender].debt);
    }

    /**
     * @notice Repay borrowed debt tokens
     * @param _amount The amount of debt tokens to repay
     * @dev Resets debt if full amount is repaid, emit Repaid event
     */
    function repayLoan(uint256 _amount) external nonReentrant whenNotPaused noFlashLoans {
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        uint256 remainingDebt = getUserLoanInfo(msg.sender).debt;
        if (_amount > remainingDebt) revert Lending__AmountExceedsLimit();

        IERC20(i_debtToken).safeTransferFrom(msg.sender, address(this), _amount);
        s_loans[msg.sender].repaid += _amount;

        // <= just because this is very critical, _resetDebt only called by liquidate() and this function
        if (getUserLoanInfo(msg.sender).debt <= getUserLoanInfo(msg.sender).repaid) {
            _resetDebt(msg.sender);
        }

        emit Repaid(msg.sender, _amount);
    }

    /**
     * @notice Raise collateral token from community in returns for interest in form of debt token
     * @param _token The address of collateral token to raise
     * @param _target The amount of collateral token to raise
     * @param _interestRateBPS The amount of interest rate promised in BPS
     * @dev emit RaisingCollateral event
     */
    function startCollateralRaising(address _token, uint256 _target, uint16 _interestRateBPS)
        external
        whenNotPaused
        noFlashLoans
    {
        (bool open,,,,,,) = getUserCollateralRaisingInfo(msg.sender);
        if (open) revert Lending__CollateralRaisingAlreadyOpen();
        if (_target <= 0) revert Lending__MustBeMoreThanZero();
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (s_priceFeeds[_token] == address(0)) revert Lending__CollateralNotSupported();

        s_collateralRaisings[msg.sender].isOpen = true;
        s_collateralRaisings[msg.sender].interestRateInBPS = _interestRateBPS;
        s_collateralRaisings[msg.sender].collateralToken = _token;
        s_collateralRaisings[msg.sender].target = _target;

        emit RaisingCollateral(msg.sender, _token, _target, _interestRateBPS);
    }

    /**
     * @notice Fund user that currently raising collateral
     * @param _user The address of user that raising collateral
     * @param _amount The amount of collateral token to fund the user
     * @dev emit CollateralFunded event
     */
    function fundUser(address _user, uint256 _amount) external nonReentrant whenNotPaused {
        (bool isOpen,, uint256 target, uint256 raised,,,) = getUserCollateralRaisingInfo(_user);

        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_amount > (target - raised)) revert Lending__AmountExceedsLimit();
        if (!isOpen) revert Lending__CollateralRaisingAlreadyClosed();
        if (target == raised) revert Lending__CollateralRaisingTargetReached();
        if (_user == address(0)) revert Lending__InvalidAddress();

        s_collateralRaisings[_user].raised += _amount;
        if (s_collateralRaisings[_user].funderInfo[msg.sender].amount == 0) {
            s_collateralRaisings[_user].funders.push(msg.sender);
        }
        s_collateralRaisings[_user].funderInfo[msg.sender].amount += _amount;
        IERC20(s_collateralRaisings[_user].collateralToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit CollateralFunded(_user, msg.sender, _amount);
    }

    /**
     * @notice End the current collateral raising period
     * @param _user The user that their raising will be ended
     * @dev Emits CollateralRaisingEnded event
     */
    function closeCollateralRaising(address _user) external whenNotPaused {
        (
            bool open,
            address collateralToken,
            uint256 target,
            uint256 raised,
            uint256 interestRateInBPS,
            address[] memory funders,
        ) = getUserCollateralRaisingInfo(_user);
        if (!open) revert Lending__CollateralRaisingAlreadyClosed();
        if (_user == address(0)) revert Lending__InvalidAddress();

        // only msg.sender allowed to close the raising before reached targe
        if (msg.sender != _user) {
            if (raised < target) {
                revert Lending__CollateralRaisingTargetNotMet();
            }
        }

        s_collateralDeposited[_user][collateralToken] += raised;
        uint256 pricePerToken = PriceFeedLib.convertPriceToTokenAmount(
            getPriceFeed(collateralToken), i_debtTokenPriceFeed, PRICE_STALE_TIME
        ); // i_debtTokenPriceFeed could use some view function

        uint256 funderLength = funders.length;
        for (uint256 i = 0; i < funderLength;) {
            uint256 amountFunded = s_collateralRaisings[_user].funderInfo[funders[i]].amount;
            uint256 totalRewardInDebtToken = PriceFeedLib.getTokenTotalPrice(pricePerToken, amountFunded);

            s_collateralRaisings[_user].funderInfo[funders[i]].reward =
                (totalRewardInDebtToken * interestRateInBPS) / BPS_DENOMINATOR;

            unchecked {
                i++;
            }
        }

        s_collateralRaisings[_user].isOpen = false;
        emit CollateralRaisingClosed(_user);
    }

    /**
     * @notice Repay both collateral and interest to a funder in a single transaction
     * @param _funder The address of the funder to repay
     * @param _collateralAmount The amount of collateral tokens to repay
     * @param _interestAmount The amount of debt tokens to pay as interest
     * @dev Emits both CollateralRepayment and InterestPaid events
     */
    function repayFunder(address _funder, uint256 _collateralAmount, uint256 _interestAmount)
        external
        nonReentrant
        whenNotPaused
    {
        CollateralRaising storage raising = s_collateralRaisings[msg.sender];

        if (_collateralAmount == 0 && _interestAmount == 0) revert Lending__MustBeMoreThanZero();
        if (raising.isOpen) revert Lending__CollateralRaisingTargetNotMet(); // still open (interest not calculated yet)
        if (_funder == address(0)) revert Lending__InvalidAddress();

        // Handle collateral repayment
        if (_collateralAmount > 0) {
            if (_collateralAmount > raising.funderInfo[_funder].amount) {
                revert Lending__AmountExceedsLimit();
            }

            raising.funderInfo[_funder].amount -= _collateralAmount;
            IERC20(raising.collateralToken).safeTransferFrom(msg.sender, _funder, _collateralAmount);

            emit CollateralRepayment(msg.sender, _funder, _collateralAmount);
        }

        // Handle interest payment
        if (_interestAmount > 0) {
            if (_interestAmount > raising.funderInfo[_funder].reward) {
                revert Lending__AmountExceedsLimit();
            }

            raising.funderInfo[_funder].reward -= _interestAmount;
            IERC20(i_debtToken).safeTransferFrom(msg.sender, _funder, _interestAmount);

            emit InterestPaid(msg.sender, _funder, _interestAmount);
        }
    }

    /**
     * @notice Liquidate user at 'underwater' position and swap the token to debtToken
     * @param _user The address of user to liquidate
     * @param _token The address of collateral token to liquidate
     */
    function liquidate(address _user, address _token) external nonReentrant whenNotPaused noFlashLoans {
        uint256 healthFactor = _calculateHealthFactorBPS(_user);
        Loan memory loan = getUserLoanInfo(_user);
        uint256 totalDebt = loan.debt - loan.repaid;

        if (getPriceFeed(_token) == address(0)) revert Lending__CollateralNotSupported();
        if (_user == address(0) || _token == address(0)) revert Lending__InvalidAddress();
        if (totalDebt == 0) revert Lending__NotLiquidatable();
        if (healthFactor >= HEALTH_FACTOR_THRESHOLD_BPS) {
            // dueDate bypass healthFactor check
            if (loan.dueDate > block.timestamp) revert Lending__NotLiquidatable();
        }

        uint256 seizeAmount = (totalDebt * (BPS_DENOMINATOR + LIQUIDATION_PENALTY_BPS)) / BPS_DENOMINATOR;
        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(s_priceFeeds[_token], i_debtTokenPriceFeed, PRICE_STALE_TIME);
        uint256 amountCollateralToSeize = PriceFeedLib.getTokenTotalPrice(pricePerToken, seizeAmount);

        uint256 userCollateral = s_collateralDeposited[_user][_token];
        if (amountCollateralToSeize > userCollateral) {
            amountCollateralToSeize = userCollateral;
        }

        s_collateralDeposited[_user][_token] -= amountCollateralToSeize;
        _resetDebt(_user);

        _swapCollateralToDebtToken(_token, amountCollateralToSeize);

        emit Liquidated(_user, _token, amountCollateralToSeize);
    }

    /**
     * @notice Reset a collateral raising detail to zero
     * @param _user The address of the user to reset
     */
    function resetCollateralRaising(address _user) external {
        (,,,,, address[] memory funderList,) = getUserCollateralRaisingInfo(_user);
        uint256 funderLength = funderList.length;

        if (funderLength == 0) revert Lending__CollateralRaisingAlreadyClosed();
        if (_user == address(0)) revert Lending__InvalidAddress();

        for (uint256 i = 0; i < funderLength;) {
            // check and effect in one go
            if (s_collateralRaisings[_user].funderInfo[funderList[i]].amount > 0) {
                revert Lending__UnsettledCollateralDebt();
            }
            if (s_collateralRaisings[_user].funderInfo[funderList[i]].reward > 0) {
                revert Lending__UnsettledInterestDebt();
            }

            delete s_collateralRaisings[_user].funderInfo[funderList[i]];

            unchecked {
                i++;
            }
        }

        delete s_collateralRaisings[_user];
    }

    // ==============================================
    // Admin Functions
    // ==============================================

    /**
     * @notice Deposit debt token to the protocol for liquidity
     * @param _amount The amount of token to add
     */
    function depositDebtToken(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert Lending__MustBeMoreThanZero();
        IERC20(i_debtToken).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Withdraw debt token from the protocol
     * @param _amount The amount of token to withdraw
     */
    function withdrawDebtToken(uint256 _amount) external onlyOwner {
        uint256 balance = IERC20(i_debtToken).balanceOf(address(this));

        if (_amount == 0) revert Lending__MustBeMoreThanZero();
        if (_amount > balance) revert Lending__InsufficientLiquidity();

        IERC20(i_debtToken).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Add a new supported collateral token
     * @param _token The address of the token to support
     * @param _priceFeed The Chainlink price feed for the token
     * @dev Only callable by owner with valid parameters, emit CollateralTokenAdded event
     */
    function addCollateralToken(address _token, address _priceFeed) external onlyOwner {
        if (_token == address(0) || _priceFeed == address(0)) revert Lending__InvalidAddress();
        if (!(s_priceFeeds[_token] == address(0))) revert Lending__TokenAlreadySupported();

        s_collateralTokens.push(_token);
        s_priceFeeds[_token] = _priceFeed;

        emit CollateralTokenAdded(_token, _priceFeed);
    }

    /**
     * @notice Remove a collateral token from support
     * @param _token The address of the token to remove
     * @dev Only callable by owner for supported tokens, emit CollateralTokenRemoved event
     */
    function removeCollateralToken(address _token) external onlyOwner {
        if (s_priceFeeds[_token] == address(0)) revert Lending__CollateralNotSupported();

        uint256 collateralTokenLength = s_collateralTokens.length;
        for (uint256 i = 0; i < collateralTokenLength;) {
            if (s_collateralTokens[i] == _token) {
                s_collateralTokens[i] = s_collateralTokens[s_collateralTokens.length - 1];
                s_collateralTokens.pop();
                break;
            }

            unchecked {
                i++;
            }
        }

        emit CollateralTokenRemoved(_token);
    }

    /**
     * @notice Update the price feed for a collateral token
     * @param _token The address of the token to update
     * @param _newPriceFeed The new price feed address
     * @dev Only callable by owner for supported tokens, emit PriceFeedUpdated event
     */
    function updatePriceFeed(address _token, address _newPriceFeed) external onlyOwner {
        if (_newPriceFeed == address(0)) revert Lending__InvalidAddress();
        if (s_priceFeeds[_token] == address(0)) revert Lending__CollateralNotSupported();

        s_priceFeeds[_token] = _newPriceFeed;
        emit PriceFeedUpdated(_token, _newPriceFeed);
    }

    /**
     * @notice Set loan parameter like interest rate and duration limit
     * @param _newRate The new value for interest rate
     * @param _newDuration The new value for duration time limit
     * @dev Emit LoanParamsChanged event
     */
    function setLoanParams(uint16 _newRate, uint32 _newDuration) external onlyOwner {
        if (_newRate > BPS_DENOMINATOR) revert Lending__AmountExceedsLimit();
        s_interestRateInBPS = _newRate;
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
     * @notice Reset a user's debt to zero
     * @param _user The address of the user to reset
     */
    function _resetDebt(address _user) internal {
        delete s_loans[_user];
    }

    /**
     * @notice Calculate the health factor of a position
     * @param _user The address of the user to check
     * @return healthFactor The health factor as 18 decimal fixed point number
     */
    function _calculateHealthFactorBPS(address _user) internal view returns (uint256 healthFactor) {
        uint256 collateralValue = getTotalCollateralValueInDebtToken(_user);
        Loan memory loan = getUserLoanInfo(_user);
        uint256 debtValue = loan.debt - loan.repaid;

        if (debtValue == 0) return type(uint256).max;
        healthFactor = (collateralValue * LTV_BPS * HEALTH_FACTOR_THRESHOLD_BPS) / (debtValue * BPS_DENOMINATOR);
    }

    /**
     * @notice Swap collateral to debt token
     * @param _token The address of token to swap
     * @param _amount The amount of token to swap
     */
    function _swapCollateralToDebtToken(address _token, uint256 _amount) internal {
        IERC20(_token).forceApprove(address(i_uniswapRouter), _amount);

        address[] memory path = new address[](2);
        path[0] = _token;
        path[1] = address(i_debtToken);

        IUniswapV2Router02(i_uniswapRouter).swapExactTokensForTokens(
            _amount,
            0,
            /// @dev the amount out currently set to 0 for testing purposes
            path,
            address(this),
            block.timestamp + 300
        );
    }

    function _getDebtTokenPriceInUsd() internal view returns (uint256) {
        PriceFeedLib.PriceData memory debt = PriceFeedLib.getNormalizedPrice(i_debtTokenPriceFeed, PRICE_STALE_TIME);
        return PriceFeedLib.scaleTo18Decimals(debt.value, debt.decimals);
    }

    // ==============================================
    // View Functions
    // ==============================================

    /**
     * @notice get a user loan information
     * @param _user The address of user to query
     */
    function getUserLoanInfo(address _user) public view returns (Loan memory) {
        return s_loans[_user];
    }

    /**
     * @notice Get the total collateral value of a user in terms
     * @param _user The address of the user to query
     * @return totalValue The total collateral value in debt token terms
     */
    function getTotalCollateralValueInDebtToken(address _user) public view returns (uint256 totalValue) {
        if (_user == address(0)) revert Lending__InvalidAddress();
        uint256 collateralTokenLength = s_collateralTokens.length;

        for (uint256 i = 0; i < collateralTokenLength;) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];

            if (amount > 0) {
                uint256 tokenPrice =
                    PriceFeedLib.convertPriceToTokenAmount(s_priceFeeds[token], i_debtTokenPriceFeed, PRICE_STALE_TIME);
                totalValue += PriceFeedLib.getTokenTotalPrice(tokenPrice, amount);
            }

            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice get all collateral token addresses
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Get a user's collateral balance for a specific token
     * @param _token The address of the token to query
     * @return The collateral balance amount
     */
    function getCollateralBalance(address _token) public view returns (uint256) {
        return s_collateralDeposited[msg.sender][_token];
    }

    /**
     * @notice Get the user collateral raising detail
     * @param _user the collateral raising detail
     */
    function getUserCollateralRaisingInfo(address _user)
        public
        view
        returns (
            bool isOpen,
            address collateralToken,
            uint256 target,
            uint256 raised,
            uint256 interestRateInBPS,
            address[] memory funders,
            FunderInfo[] memory funderInfo
        )
    {
        CollateralRaising storage raising = s_collateralRaisings[_user];
        address[] memory allFunder = raising.funders;

        uint256 funderLength = raising.funders.length;
        FunderInfo[] memory allFunderInfo = new FunderInfo[](funderLength);

        for (uint256 i = 0; i < funderLength;) {
            allFunderInfo[i] = raising.funderInfo[allFunder[i]];
            unchecked {
                i++;
            }
        }

        return (
            raising.isOpen,
            raising.collateralToken,
            raising.target,
            raising.raised,
            raising.interestRateInBPS,
            allFunder,
            allFunderInfo
        );
    }

    /**
     * @notice Get the price feed address for a token
     * @param _token The address of token
     * @return The address of price feed
     */
    function getPriceFeed(address _token) public view returns (address) {
        if (s_priceFeeds[_token] == address(0)) revert Lending__CollateralNotSupported();

        return s_priceFeeds[_token];
    }
}
