// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {PriceFeedLib} from "./libs/PriceFeedLib.sol";
import {IERC20WithDecimals} from "./interfaces/IERC20WithDecimals.sol";

/**
 * @title Lending App with Oracle Integration
 * @author Lexy Samuel
 * @notice Collateral-based lending system with fixed interest, collateral raising, and Chainlink price feeds
 * @dev Implements loan-to-value (LTV) checks, liquidation, and interest rate management
 */
contract Lending is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==============================================
    // Events
    // ==============================================
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
    error Lending__AccessDenied();
    error Lending__MustBeMoreThanZero();
    error Lending__AmountExceedsLimit();
    error Lending__InsufficientLiquidity();
    error Lending__InsufficientCollateral();
    error Lending__OutstandingDebt();
    error Lending__LTVViolation();
    error Lending__TokenNotSupported();
    error Lending__TokenAlreadySupported();
    error Lending__PriceFeedNotAvailable();
    error Lending__NotLiquidatable();
    error Lending__CollateralRaisingAlreadyOpen();
    error Lending__CollateralRaisingAlreadyClosed();
    error Lending__CollateralRaisingTargetReached();
    error Lending__CollateralRaisingTargetNotMet();
    error Lending__UnsettledDebt();

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
    uint8 public constant DEFAULT_DECIMALS = 18;
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
    mapping(address token => uint8 decimals) private s_tokenDecimals;

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
        s_tokenDecimals[_debtToken] = IERC20WithDecimals(_debtToken).decimals();
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
     * @dev The token must be supported as collateral and amount must be > 0
     */
    function depositCollateral(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (s_priceFeeds[_token] == address(0)) revert Lending__TokenNotSupported();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_token == address(0)) revert Lending__InvalidAddress();

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        s_collateralDeposited[msg.sender][_token] += _amount;
    }

    /**
     * @notice Withdraw deposited collateral tokens
     * @param _token The address of the collateral token to withdraw
     * @param _amount The amount of tokens to withdraw
     * @dev Requires no outstanding debt and maintains LTV ratio
     */
    function withdrawCollateral(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_getUserLoanInfo(msg.sender).debt > 0) revert Lending__OutstandingDebt();
        if (_calculateHealthFactorBPS(msg.sender) < HEALTH_FACTOR_THRESHOLD_BPS) revert Lending__LTVViolation();
        if (_amount > getCollateralBalance(_token)) revert Lending__InsufficientCollateral();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();
        if (_token == address(0)) revert Lending__InvalidAddress();

        s_collateralDeposited[msg.sender][_token] -= _amount;
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Borrow debt tokens against deposited collateral
     * @param _amount The amount of debt tokens to borrow
     * @dev The borrow amount must be within the LTV ratio of collateral value, emit Borrowed event
     */
    function takeLoan(uint256 _amount) external nonReentrant whenNotPaused noFlashLoans {
        if (_getUserLoanInfo(msg.sender).debt > 0) revert Lending__OutstandingDebt();
        if (_amount > IERC20(i_debtToken).balanceOf(address(this))) revert Lending__InsufficientLiquidity();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        uint256 collateralValue = getTotalCollateralValueInDebtToken(msg.sender);
        uint256 maxLoan = (collateralValue * LTV_BPS) / BPS_DENOMINATOR;
        if (_amount > maxLoan) revert Lending__AmountExceedsLimit();

        Loan storage loan = s_loans[msg.sender];

        loan.debt = _amount + ((_amount * s_interestRateInBPS) / BPS_DENOMINATOR); // apply interest
        loan.dueDate = uint32(block.timestamp + s_loanDurationLimit);
        IERC20(i_debtToken).safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _amount, loan.debt);
    }

    /**
     * @notice Repay borrowed debt tokens
     * @param _amount The amount of debt tokens to repay
     * @dev Resets debt if full amount is repaid, emit Repaid event
     */
    function repayLoan(uint256 _amount) external nonReentrant whenNotPaused noFlashLoans {
        Loan storage loan = s_loans[msg.sender];
        uint256 remainingDebt = loan.debt - loan.repaid;

        if (_amount > remainingDebt) revert Lending__AmountExceedsLimit();
        if (_amount == 0) revert Lending__MustBeMoreThanZero();

        unchecked {
            loan.repaid += _amount;
        }

        IERC20(i_debtToken).safeTransferFrom(msg.sender, address(this), _amount);

        if (loan.repaid == loan.debt) {
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
        if (s_priceFeeds[_token] == address(0)) revert Lending__TokenNotSupported();
        if (_token == address(0)) revert Lending__InvalidAddress();
        if (_target <= 0) revert Lending__MustBeMoreThanZero();

        CollateralRaising storage raising = s_collateralRaisings[msg.sender];

        raising.isOpen = true;
        raising.interestRateInBPS = _interestRateBPS;
        raising.collateralToken = _token;
        raising.target = _target;

        emit RaisingCollateral(msg.sender, _token, _target, _interestRateBPS);
    }

    /**
     * @notice Fund user that currently raising collateral
     * @param _user The address of user that raising collateral
     * @param _amount The amount of collateral token to fund the user
     * @dev emit CollateralFunded event
     */
    function fundUser(address _user, uint256 _amount) external nonReentrant whenNotPaused {
        if (_user == address(0)) revert Lending__InvalidAddress();
        if (_amount <= 0) revert Lending__MustBeMoreThanZero();

        CollateralRaising storage raising = s_collateralRaisings[_user];
        bool isOpen = raising.isOpen;
        uint256 target = raising.target;
        uint256 raised = raising.raised;

        uint256 remaining = target - raised;
        if (_amount > remaining) revert Lending__AmountExceedsLimit();
        if (!isOpen) revert Lending__CollateralRaisingAlreadyClosed();
        if (remaining == 0) revert Lending__CollateralRaisingTargetReached();

        FunderInfo storage funder = raising.funderInfo[msg.sender];
        if (funder.amount == 0) {
            raising.funders.push(msg.sender);
        }

        raising.raised += _amount;
        funder.amount += _amount;
        IERC20(raising.collateralToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit CollateralFunded(_user, msg.sender, _amount);
    }

    /**
     * @notice End the current collateral raising
     * @dev Emits CollateralRaisingEnded event
     */
    function closeCollateralRaising() external whenNotPaused {
        CollateralRaising storage raising = s_collateralRaisings[msg.sender];

        if (!raising.isOpen) revert Lending__CollateralRaisingAlreadyClosed();

        address collateralToken = raising.collateralToken;
        uint256 raised = raising.raised;
        uint256 interestRateInBPS = raising.interestRateInBPS;
        address[] memory funders = raising.funders;
        uint8 debtTokenDecimals = s_tokenDecimals[i_debtToken];
        uint8 collateralTokenDecimals = s_tokenDecimals[raising.collateralToken];

        raising.isOpen = false;
        s_collateralDeposited[msg.sender][collateralToken] += raised;

        uint256 pricePerToken = PriceFeedLib.convertPriceToTokenAmount(
            getPriceFeed(collateralToken), i_debtTokenPriceFeed, PRICE_STALE_TIME
        );

        uint256 funderLength = funders.length;
        for (uint256 i = 0; i < funderLength;) {
            FunderInfo storage funderInfo = raising.funderInfo[funders[i]];
            uint256 reward = (
                PriceFeedLib.getTokenTotalPrice(
                    pricePerToken, funderInfo.amount, DEFAULT_DECIMALS, collateralTokenDecimals
                ) * interestRateInBPS
            ) / BPS_DENOMINATOR;

            funderInfo.reward += _normalizeAmount(reward, DEFAULT_DECIMALS, debtTokenDecimals);

            unchecked {
                i++;
            }
        }

        emit CollateralRaisingClosed(msg.sender);
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
        FunderInfo storage funder = raising.funderInfo[_funder];

        if (getCollateralBalance(raising.collateralToken) < _collateralAmount) revert Lending__InsufficientCollateral();
        if (_funder == address(0)) revert Lending__InvalidAddress();
        if (_collateralAmount == 0 && _interestAmount == 0) revert Lending__MustBeMoreThanZero();
        if (raising.isOpen) revert Lending__CollateralRaisingTargetNotMet();

        // Handle collateral repayment
        if (_collateralAmount > 0) {
            if (_collateralAmount > funder.amount) revert Lending__AmountExceedsLimit();
            funder.amount -= _collateralAmount;
            s_collateralDeposited[msg.sender][raising.collateralToken] -= _collateralAmount;
            IERC20(raising.collateralToken).safeTransfer(_funder, _collateralAmount);
            emit CollateralRepayment(msg.sender, _funder, _collateralAmount);
        }

        // Handle interest payment
        if (_interestAmount > 0) {
            if (_interestAmount > funder.reward) revert Lending__AmountExceedsLimit();
            funder.reward -= _interestAmount;
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
        if (_user == address(0) || _token == address(0)) revert Lending__InvalidAddress();
        address collateralPriceFeed = s_priceFeeds[_token];
        if (collateralPriceFeed == address(0)) revert Lending__TokenNotSupported();

        Loan storage loan = s_loans[_user];
        uint256 totalDebt = loan.debt - loan.repaid;
        if (totalDebt == 0) revert Lending__NotLiquidatable();

        if (_calculateHealthFactorBPS(_user) >= HEALTH_FACTOR_THRESHOLD_BPS && loan.dueDate > block.timestamp) {
            revert Lending__NotLiquidatable();
        }

        uint8 debtTokenDecimals = s_tokenDecimals[address(i_debtToken)];
        uint8 collateralDecimals = s_tokenDecimals[_token];
        // scale to 18 decimals
        uint256 userCollateral =
            _normalizeAmount(s_collateralDeposited[_user][_token], collateralDecimals, DEFAULT_DECIMALS);
        if (userCollateral == 0) revert Lending__NotLiquidatable();

        // totalToRecover in debt token using debt token decimals
        uint256 totalToRecoverNormalized = _normalizeAmount(
            (totalDebt * (BPS_DENOMINATOR + LIQUIDATION_PENALTY_BPS)) / BPS_DENOMINATOR,
            debtTokenDecimals,
            DEFAULT_DECIMALS
        );

        // Get price of 1 collateral token in debt tokens (scaled to 1e18)
        uint256 debtTokensPerCollateral =
            PriceFeedLib.convertPriceToTokenAmount(collateralPriceFeed, i_debtTokenPriceFeed, PRICE_STALE_TIME);

        // normalize to 18 decimals before swap (because uniswap require so)
        uint256 amountCollateralToSeize =
            (totalToRecoverNormalized * (10 ** DEFAULT_DECIMALS)) / debtTokensPerCollateral;

        if (amountCollateralToSeize > userCollateral) {
            amountCollateralToSeize = userCollateral;
            // increment repaid instead of clearing the debt if the collateral value cant clear the debt
            uint256 collateralValueInDebtToken = PriceFeedLib.getTokenTotalPrice(
                debtTokensPerCollateral, amountCollateralToSeize, DEFAULT_DECIMALS, DEFAULT_DECIMALS
            );
            loan.repaid += _normalizeAmount(collateralValueInDebtToken, DEFAULT_DECIMALS, debtTokenDecimals);
        } else {
            _resetDebt(_user);
        }

        s_collateralDeposited[_user][_token] -= amountCollateralToSeize;
        _swapCollateralToDebtToken(_token, amountCollateralToSeize);

        emit Liquidated(_user, _token, amountCollateralToSeize);
    }

    /**
     * @notice Reset a collateral raising detail to zero
     */
    function resetCollateralRaising() external {
        CollateralRaising storage raising = s_collateralRaisings[msg.sender];

        uint256 funderLength = raising.funders.length;
        for (uint256 i = 0; i < funderLength;) {
            FunderInfo storage funder = raising.funderInfo[raising.funders[i]];
            if (funder.amount > 0 || funder.reward > 0) {
                revert Lending__UnsettledDebt();
            }
            unchecked {
                i++;
            }
        }

        delete s_collateralRaisings[msg.sender];
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
        s_tokenDecimals[_token] = IERC20WithDecimals(_token).decimals();

        emit CollateralTokenAdded(_token, _priceFeed);
    }

    /**
     * @notice Remove a collateral token from support
     * @param _token The address of the token to remove
     * @dev Only callable by owner for supported tokens, emit CollateralTokenRemoved event
     */
    function removeCollateralToken(address _token) external onlyOwner {
        uint256 length = s_collateralTokens.length;
        bool found;

        for (uint256 i = 0; i < length;) {
            if (s_collateralTokens[i] == _token) {
                s_collateralTokens[i] = s_collateralTokens[length - 1];
                s_collateralTokens.pop();
                found = true;
                break;
            }
            unchecked {
                i++;
            }
        }

        if (!found) revert Lending__TokenNotSupported();
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
        if (s_priceFeeds[_token] == address(0)) revert Lending__TokenNotSupported();

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
     * @notice Get user loan information
     * @param _user The address of user loan information
     * @return The loan information
     */
    function _getUserLoanInfo(address _user) internal view returns (Loan memory) {
        return s_loans[_user];
    }

    /**
     * @notice Reset a user's debt to zero
     * @param _user The address of the user to reset
     */
    function _resetDebt(address _user) internal {
        delete s_loans[_user];
    }

    /**
     * @notice Normalize decimals
     */
    function _normalizeAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else if (fromDecimals < toDecimals) {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
        return amount;
    }

    /**
     * @notice Calculate the health factor of a position
     * @param _user The address of the user to check
     * @return healthFactor The health factor as 18 decimal fixed point number
     */
    function _calculateHealthFactorBPS(address _user) internal view returns (uint256) {
        uint256 collateralValue = getTotalCollateralValueInDebtToken(_user);
        Loan memory loan = _getUserLoanInfo(_user);
        uint256 debtValue = loan.debt - loan.repaid;

        if (debtValue == 0) return type(uint256).max;

        // Apply LTV to collateral first
        uint256 riskAdjustedCollateral = (collateralValue * LTV_BPS) / BPS_DENOMINATOR;

        // Then calculate health factor
        return (riskAdjustedCollateral * BPS_DENOMINATOR) / debtValue;
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

    // ==============================================
    // View Functions
    // ==============================================
    /**
     * @notice get loan information
     * @return The loan info
     */
    function getLoanInfo(address _user) public view returns (Loan memory) {
        if (msg.sender != _user && msg.sender != owner()) revert Lending__AccessDenied();
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
        uint8 debtTokenDecimals = s_tokenDecimals[i_debtToken];
        address debtTokenPriceFeed = i_debtTokenPriceFeed;

        for (uint256 i = 0; i < collateralTokenLength;) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];

            if (amount > 0) {
                if (s_priceFeeds[token] == address(0)) revert Lending__PriceFeedNotAvailable();

                uint256 tokenPrice =
                    PriceFeedLib.convertPriceToTokenAmount(s_priceFeeds[token], debtTokenPriceFeed, PRICE_STALE_TIME);

                uint8 collateralDecimals = s_tokenDecimals[token];
                uint256 tokenTotalPrice =
                    PriceFeedLib.getTokenTotalPrice(tokenPrice, amount, DEFAULT_DECIMALS, collateralDecimals);

                totalValue += _normalizeAmount(tokenTotalPrice, DEFAULT_DECIMALS, debtTokenDecimals);
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
        address[] memory allFunder = raising.funders; // Single storage read
        uint256 funderLength = allFunder.length;

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
     * @notice Get the token decimal places
     * @param _token The address of token
     * @return The number of decimal of _token
     */
    function getTokenDecimals(address _token) public view returns (uint8) {
        if (_token == address(0)) revert Lending__InvalidAddress();

        uint8 decimals = s_tokenDecimals[_token];
        if (decimals == 0) revert Lending__TokenNotSupported();

        return decimals;
    }

    /**
     * @notice Get the price feed address for a token
     * @param _token The address of token
     * @return The address of price feed
     */
    function getPriceFeed(address _token) public view returns (address) {
        if (s_priceFeeds[_token] == address(0)) revert Lending__TokenNotSupported();

        return s_priceFeeds[_token];
    }
}
