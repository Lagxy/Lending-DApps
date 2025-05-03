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
 */
contract Lending is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Errors (preserving all Lending__ prefixes)
    error Lending__MustBeMoreThanZero();
    error Lending__AmountExceeds();
    error Lending__InsufficientCollateral();
    error Lending__DebtNotZero();
    error Lending__ViolatingLTV();
    error Lending__TransferFailed();
    error Lending__TokenNotSupported();
    error Lending__MaxTokensReached();
    error Lending__StalePriceData();
    error Lending__InvalidPriceFeed();
    
    // Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 totalRepayment);
    event Repaid(address indexed user, uint256 amount);
    event CollateralTokenAdded(address indexed token, address priceFeed);
    event CollateralTokenRemoved(address indexed token);
    event InterestRateChanged(uint256 newRate);
    event Liquidated(address indexed user, address indexed token, uint256 amount);
    event DebtReset(address indexed user);
    event PriceFeedUpdated(address indexed token, address newPriceFeed);

    uint256 private constant LTV = 75; // 75% LTV ratio
    uint256 private constant MAX_COLLATERAL_TOKENS = 50;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_STALE_TIME = 86400; // 24 hours
    
    IERC20 private immutable i_debtToken;
    uint256 private s_interestRate;

    address[] private s_collateralToken;
    mapping(address => bool) private s_isCollateralSupported;
    mapping(address => uint8) private s_tokenDecimals;
    mapping(address => AggregatorV3Interface) private s_priceFeeds;
    
    mapping(address => mapping(address => uint256)) private s_collateralDeposited;
    mapping(address => uint256) private s_totalRepayment;
    mapping(address => uint256) private s_repaid;

    constructor(address initialOwner, address _debtToken) Ownable(initialOwner) {
        i_debtToken = IERC20(_debtToken);
    }

    // Main Functions
    function depositCollateral(address token, uint256 amount) external whenNotPaused {
        if(amount <= 0) revert Lending__MustBeMoreThanZero();
        if(!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        s_collateralDeposited[msg.sender][token] += amount;

        emit CollateralDeposited(msg.sender, token, amount);
    }

    function borrow(uint256 borrowAmount) external whenNotPaused {
        if(borrowAmount <= 0) revert Lending__MustBeMoreThanZero();
        if(s_totalRepayment[msg.sender] > 0) revert Lending__DebtNotZero();

        uint256 collateralValue = getTotalCollateralValue(msg.sender);
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        if(borrowAmount > maxBorrow) revert Lending__AmountExceeds();

        uint256 interest = (borrowAmount * s_interestRate) / BPS_DENOMINATOR;
        s_totalRepayment[msg.sender] = borrowAmount + interest;
        i_debtToken.safeTransfer(msg.sender, borrowAmount);

        emit Borrowed(msg.sender, borrowAmount, s_totalRepayment[msg.sender]);
    }

    function repay(uint256 amount) external whenNotPaused {
        if(amount <= 0) revert Lending__MustBeMoreThanZero();
        
        uint256 remainingDebt = getRemainingDebt(msg.sender);
        if(amount > remainingDebt) revert Lending__AmountExceeds();

        i_debtToken.safeTransferFrom(msg.sender, address(this), amount);
        s_repaid[msg.sender] += amount;

        if(s_repaid[msg.sender] == s_totalRepayment[msg.sender]) {
            _resetDebt(msg.sender);
        }

        emit Repaid(msg.sender, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external whenNotPaused {
        if(amount <= 0) revert Lending__MustBeMoreThanZero();
        if(amount > s_collateralDeposited[msg.sender][token]) revert Lending__InsufficientCollateral();
        if(getRemainingDebt(msg.sender) > 0) revert Lending__DebtNotZero();

        s_collateralDeposited[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    function liquidate(address user, address collateralToken) external whenNotPaused {
        uint256 collateralValue = getTotalCollateralValue(user);
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        
        if(s_totalRepayment[user] > maxBorrow) {
            uint256 collateralAmount = s_collateralDeposited[user][collateralToken];
            delete s_collateralDeposited[user][collateralToken];
            IERC20(collateralToken).safeTransfer(msg.sender, collateralAmount);
            
            emit Liquidated(user, collateralToken, collateralAmount);
        } else {
            revert Lending__ViolatingLTV();
        }
    }

    // Admin Functions
    function addCollateralToken(address token, address priceFeed) external onlyOwner {
        if(token == address(0)) revert Lending__MustBeMoreThanZero();
        if(priceFeed == address(0)) revert Lending__InvalidPriceFeed();
        if(s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if(s_collateralToken.length >= MAX_COLLATERAL_TOKENS) revert Lending__MaxTokensReached();
        
        s_collateralToken.push(token);
        s_isCollateralSupported[token] = true;
        s_tokenDecimals[token] = IERC20Metadata(token).decimals();
        s_priceFeeds[token] = AggregatorV3Interface(priceFeed);
        
        emit CollateralTokenAdded(token, priceFeed);
    }

    function updatePriceFeed(address token, address newPriceFeed) external onlyOwner {
        if(!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        if(newPriceFeed == address(0)) revert Lending__InvalidPriceFeed();
        
        s_priceFeeds[token] = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(token, newPriceFeed);
    }

    function removeCollateralToken(address token) external onlyOwner {
        if(!s_isCollateralSupported[token]) revert Lending__TokenNotSupported();
        
        for(uint256 i = 0; i < s_collateralToken.length; i++) {
            if(s_collateralToken[i] == token) {
                s_collateralToken[i] = s_collateralToken[s_collateralToken.length - 1];
                s_collateralToken.pop();
                break;
            }
        }
        
        s_isCollateralSupported[token] = false;
        emit CollateralTokenRemoved(token);
    }

    function setInterestRate(uint256 newRate) external onlyOwner {
        if(newRate > BPS_DENOMINATOR) revert Lending__AmountExceeds();
        s_interestRate = newRate;
        emit InterestRateChanged(newRate);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Internal Functions
    function _resetDebt(address user) private {
        s_totalRepayment[user] = 0;
        s_repaid[user] = 0;
        emit DebtReset(user);
    }

    // View Functions
    function getTokenPrice(address token) public view returns (uint256) {
        AggregatorV3Interface priceFeed = s_priceFeeds[token];
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        
        if (price <= 0) revert Lending__InvalidPriceFeed();
        if (block.timestamp - updatedAt > PRICE_STALE_TIME) revert Lending__StalePriceData();
        
        uint8 priceFeedDecimals = priceFeed.decimals();
        return uint256(price) * (10 ** (18 - priceFeedDecimals));
    }

    function getTotalCollateralValue(address user) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address token = s_collateralToken[i];
            uint256 amount = s_collateralDeposited[user][token];
            if(amount > 0) {
                uint256 price = getTokenPrice(token);
                uint256 decimals = s_tokenDecimals[token];
                totalValue += (amount * price) / (10 ** decimals);
            }
        }
    }

    function getRemainingDebt(address user) public view returns (uint256) {
        uint256 totalDebt = s_totalRepayment[user];
        uint256 repaid = s_repaid[user];
        return totalDebt > repaid ? totalDebt - repaid : 0;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralToken;
    }

    function getCollateralBalance(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getTotalRepayment(address user) external view returns (uint256) {
        return s_totalRepayment[user];
    }

    function getRepaidAmount(address user) external view returns (uint256) {
        return s_repaid[user];
    }

    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    function isCollateralSupported(address token) external view returns (bool) {
        return s_isCollateralSupported[token];
    }

    function getPriceFeed(address token) external view returns (address) {
        return address(s_priceFeeds[token]);
    }
}