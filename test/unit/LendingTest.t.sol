// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {Lending} from "../../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MockAggregatorV3Interface} from "../mocks/MockAggregatorV3Interface.sol";
import {PriceFeedLib} from "../../src/PriceFeedLib.sol";

contract LendingTest is Test {
    Lending public lending;
    ERC20Mock public debtToken;
    ERC20Mock public collateralToken1;
    ERC20Mock public collateralToken2;
    MockV3Aggregator public priceFeed1;
    MockV3Aggregator public priceFeed2;
    MockAggregatorV3Interface public debtTokenPriceFeed;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 public constant PRICE_STALE_TIME = 24 hours;
    uint256 public constant INITIAL_INTEREST_RATE = 500; // 5% in BPS
    uint256 public constant LTV_BPS = 7000; // 70% LTV in BPS
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_PRECISION = 1e18; // Used for inverse price calculations
    int256 public constant PRICE_1 = 2000 * 1e8; // $2000 with 8 decimals
    int256 public constant PRICE_2 = 1 * 1e8; // $1 with 8 decimals
    int256 public constant IDRX_USD_PRICE = 605000000000; // $0.0000605 with 8 decimals
    address public constant UNISWAP_ROUTER_V2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock tokens
        debtToken = new ERC20Mock();
        collateralToken1 = new ERC20Mock();
        collateralToken2 = new ERC20Mock();

        // Deploy mock price feeds with int256 prices
        priceFeed1 = new MockV3Aggregator(8, PRICE_1);
        priceFeed2 = new MockV3Aggregator(8, PRICE_2);

        // Deploy mock price feed for debt token
        debtTokenPriceFeed = new MockAggregatorV3Interface(owner, IDRX_USD_PRICE, 8);

        // Deploy lending contract
        lending = new Lending(owner, address(debtToken), address(debtTokenPriceFeed), UNISWAP_ROUTER_V2);

        // Add collateral tokens
        lending.addCollateralToken(address(collateralToken1), address(priceFeed1));
        lending.addCollateralToken(address(collateralToken2), address(priceFeed2));

        // Add liquidity to the protocol
        debtToken.mint(address(lending), 100_000_000 * 1e18);

        // Mint token to user
        collateralToken1.mint(user1, 10 * 1e18);
        collateralToken1.mint(user2, 10 * 1e18);
        collateralToken2.mint(user1, 10_000 * 1e6);
        collateralToken2.mint(user2, 10_000 * 1e6);

        vm.stopPrank();
    }

    // ============ Deposit Collateral Tests ============
    function test_depositCollateral() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralDeposited(user1, address(collateralToken1), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        assertEq(lending.getCollateralBalance(address(collateralToken1)), depositAmount);
        assertEq(collateralToken1.balanceOf(user1), 10 * 1e18 - depositAmount);
        vm.stopPrank();
    }

    function test_depositCollateral_RevertIfAmountZero() public {
        vm.startPrank(user1);
        collateralToken1.approve(address(lending), 1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.depositCollateral(address(collateralToken1), 0);
        vm.stopPrank();
    }

    function test_depositCollateral_RevertIfTokenNotSupported() public {
        ERC20Mock unsupportedToken = new ERC20Mock();

        vm.startPrank(user1);
        unsupportedToken.approve(address(lending), 1);
        vm.expectRevert(Lending.Lending__CollateralNotSupported.selector);
        lending.depositCollateral(address(unsupportedToken), 1);
        vm.stopPrank();
    }

    // ============ Withdraw Collateral Tests ============
    function test_withdrawCollateral() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 withdrawAmount = 0.5 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralWithdrawn(user1, address(collateralToken1), withdrawAmount);
        lending.withdrawCollateral(address(collateralToken1), withdrawAmount);

        assertEq(lending.getCollateralBalance(address(collateralToken1)), depositAmount - withdrawAmount);
        assertEq(collateralToken1.balanceOf(user1), 10 * 1e18 - depositAmount + withdrawAmount);
        vm.stopPrank();
    }

    function test_withdrawCollateral_RevertIfAmountZero() public {
        vm.startPrank(user1, user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.withdrawCollateral(address(collateralToken1), 0);
        vm.stopPrank();
    }

    function test_withdrawCollateral_RevertIfInsufficientCollateral() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        vm.expectRevert(Lending.Lending__InsufficientCollateral.selector);
        lending.withdrawCollateral(address(collateralToken1), depositAmount + 1);
        vm.stopPrank();
    }

    function test_withdrawCollateral_RevertIfDebtNotZero() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 maxBorrow = PriceFeedLib.getTokenTotalPrice(pricePerToken, depositAmount);
        uint256 borrowAmount = maxBorrow / 2; // Borrow half of max

        lending.takeLoan(borrowAmount);

        vm.expectRevert(Lending.Lending__OutstandingDebt.selector);
        lending.withdrawCollateral(address(collateralToken1), depositAmount);
        vm.stopPrank();
    }

    // ============ Take Loan Tests ============
    function test_takeLoan() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 maxBorrow = PriceFeedLib.getTokenTotalPrice(pricePerToken, depositAmount);
        uint256 protocolLiquidity = debtToken.balanceOf(address(lending));

        uint256 borrowAmount = protocolLiquidity > maxBorrow ? (maxBorrow / 2) : (protocolLiquidity / 2); // ensure borrowAmount smaller than maxBorrow and smaller than protocolLiquidity

        uint256 expectedDebt = borrowAmount + ((borrowAmount * lending.s_interestRateInBPS()) / BPS_DENOMINATOR);

        vm.expectEmit(true, true, true, true);
        emit Lending.Borrowed(user1, borrowAmount, expectedDebt);
        lending.takeLoan(borrowAmount);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(user1), borrowAmount);
    }

    function test_takeLoan_RevertIfInsufficientLiquidity() public {
        uint256 availableDebtToken = debtToken.balanceOf(address(lending));

        uint256 depositAmount = 10e18;
        uint256 borrowAmount = availableDebtToken * 2;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        vm.expectRevert(Lending.Lending__InsufficientLiquidity.selector);
        lending.takeLoan(borrowAmount);
        vm.stopPrank();
    }

    function test_takeLoan_RevertIfAmountZero() public {
        vm.startPrank(user1, user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.takeLoan(0);
        vm.stopPrank();
    }

    function test_takeLoan_RevertIfExistingDebt() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 maxBorrow = PriceFeedLib.getTokenTotalPrice(pricePerToken, depositAmount);
        uint256 borrowAmount = maxBorrow / 4; // borrow 1/4 of max

        lending.takeLoan(borrowAmount);

        vm.expectRevert(Lending.Lending__OutstandingDebt.selector);
        lending.takeLoan(borrowAmount);
        vm.stopPrank();
    }

    function test_takeLoan_RevertIfExceedsLTV() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        // Does not follow AAA (Arrange, Act, Assert) Pattern
        uint256 collateralValue = lending.getTotalCollateralValueInDebtToken(user1);
        uint256 maxBorrow = (collateralValue * LTV_BPS) / BPS_DENOMINATOR;
        uint256 borrowAmount = maxBorrow + 1; // Exceeds LTV

        vm.expectRevert(Lending.Lending__AmountExceedsLimit.selector);
        lending.takeLoan(borrowAmount);
        vm.stopPrank();
    }

    // ============ Repay Loan Tests ============
    function test_repayLoan() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 maxBorrow = PriceFeedLib.getTokenTotalPrice(pricePerToken, depositAmount);
        uint256 borrowAmount = maxBorrow / 4; // Borrow 1/4 of max
        uint256 repayAmount = borrowAmount / 2; // try to repay half borrow amount

        lending.takeLoan(borrowAmount);

        debtToken.approve(address(lending), repayAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.Repaid(user1, repayAmount);
        lending.repayLoan(repayAmount);
        vm.stopPrank();

        uint256 debt = lending.getUserLoanInfo(user1).debt;
        assertEq(lending.getUserLoanInfo(user1).debt - lending.getUserLoanInfo(user1).repaid, debt - repayAmount);
        assertEq(lending.getUserLoanInfo(user1).repaid, repayAmount);
    }

    function test_repayLoan_RevertIfAmountZero() public {
        vm.startPrank(user1, user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.repayLoan(0);
        vm.stopPrank();
    }

    function test_repayLoan_RevertIfAmountExceedsDebt() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 maxBorrow = PriceFeedLib.getTokenTotalPrice(pricePerToken, depositAmount);
        uint256 borrowAmount = maxBorrow / 4; // Borrow 1/4 of max

        lending.takeLoan(borrowAmount);

        uint256 debt = lending.getUserLoanInfo(user1).debt;
        debtToken.approve(address(lending), debt + 1);

        vm.expectRevert(Lending.Lending__AmountExceedsLimit.selector);
        lending.repayLoan(debt + 1);
        vm.stopPrank();
    }

    function test_repayLoan_FullRepaymentResetsDebt() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 pricePerToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 maxBorrow = PriceFeedLib.getTokenTotalPrice(pricePerToken, depositAmount);
        uint256 borrowAmount = maxBorrow / 4; // Borrow 1/4 of max

        lending.takeLoan(borrowAmount);

        uint256 debt = lending.getUserLoanInfo(user1).debt;
        debtToken.approve(address(lending), debt);
        vm.stopPrank();

        // assuming user1 get debtToken from external source
        vm.startPrank(owner);
        debtToken.mint(user1, 100_000e18); // just random big value but can also use existing variable
        vm.stopPrank();

        vm.startPrank(user1, user1);
        lending.repayLoan(debt);
        vm.stopPrank();

        assertEq(lending.getUserLoanInfo(user1).debt, 0);
        assertEq(lending.getUserLoanInfo(user1).repaid, 0);
    }

    // ============ Start Collateral Raising Tests ============

    // ============ Fund User Tests ============

    // ============ Cancel Collateral Raising Tests ============

    // ============ End Collateral Raising Tests ============

    // ============ Repay Funder Collateral Tests ============

    // ============ Pay Funder Interest Tests ============

    // ============ Liquidate Tests ============

    // ============ Admin Function Tests ============
    function test_depositDebtToken() public {}

    function test_withdrawDebtToken() public {}

    function test_addCollateralToken() public {
        ERC20Mock newToken = new ERC20Mock();
        MockV3Aggregator newPriceFeed = new MockV3Aggregator(8, PRICE_1);

        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralTokenAdded(address(newToken), address(newPriceFeed));
        lending.addCollateralToken(address(newToken), address(newPriceFeed));

        address[] memory collateralTokens = lending.getCollateralTokens();
        assertEq(collateralTokens[collateralTokens.length - 1], address(newToken));
    }

    function test_addCollateralToken_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.addCollateralToken(address(collateralToken1), address(priceFeed1));
    }

    function test_updatePriceFeed() public {
        MockV3Aggregator newPriceFeed = new MockV3Aggregator(8, PRICE_2);

        // uint256 oldPrice = lending.getTokenPriceInDebtToken(address(collateralToken1));
        uint256 oldPrice = PriceFeedLib.convertPriceToTokenAmount(
            lending.getPriceFeed(address(collateralToken1)), address(debtTokenPriceFeed), PRICE_STALE_TIME
        );

        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.PriceFeedUpdated(address(collateralToken1), address(newPriceFeed));
        lending.updatePriceFeed(address(collateralToken1), address(newPriceFeed));

        uint256 newPrice = PriceFeedLib.convertPriceToTokenAmount(
            lending.getPriceFeed(address(collateralToken1)), address(debtTokenPriceFeed), PRICE_STALE_TIME
        );

        // should've check the address
        assertNotEq(oldPrice, newPrice);
    }

    function test_updatePriceFeed_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.updatePriceFeed(address(collateralToken1), address(priceFeed1));
    }

    function test_removeCollateralToken() public {
        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralTokenRemoved(address(collateralToken1));
        lending.removeCollateralToken(address(collateralToken1));
    }

    function test_removeCollateralToken_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.removeCollateralToken(address(collateralToken1));
    }

    function test_setLoanParams() public {
        uint16 newRate = 1000; // 10%
        uint32 newDuration = 90 days;

        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.LoanParamsChanged(newRate, newDuration);
        lending.setLoanParams(newRate, newDuration);

        assertEq(lending.s_interestRateInBPS(), newRate);
        assertEq(lending.s_loanDurationLimit(), newDuration);
    }

    function test_setLoanParams_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.setLoanParams(1000, 1);
    }

    function test_setLoanParams_RevertIfExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(Lending.Lending__AmountExceedsLimit.selector);
        lending.setLoanParams(10001, 1); // 100.01% (exceeds BPS_DENOMINATOR)
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        lending.pause();
        assertTrue(lending.paused());

        vm.prank(owner);
        lending.unpause();
        assertFalse(lending.paused());
    }

    function test_pause_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.pause();
    }

    // ============ View Function Tests ============
    function test_getTotalCollateralValueInDebtToken() public {}

    function test_getCollateralTokens() public view {
        address[] memory tokens = lending.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(collateralToken1));
        assertEq(tokens[1], address(collateralToken2));
    }

    function test_getCollateralBalance() public {}

    function test_getCollateralRaisingDetails() public {}
}
