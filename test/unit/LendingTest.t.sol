// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {Lending} from "../../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MockAggregatorV3Interface} from "../mocks/MockAggregatorV3Interface.sol";
import {MockUniswapV2Router} from "../mocks/MockUniswapV2Router.sol";
import {PriceFeedLib} from "../../src/libs/PriceFeedLib.sol";

contract LendingTest is Test {
    Lending public lending;
    ERC20Mock public debtToken;
    ERC20Mock public collateralToken1;
    ERC20Mock public collateralToken2;
    MockV3Aggregator public priceFeed1;
    MockV3Aggregator public priceFeed2;
    MockAggregatorV3Interface public debtTokenPriceFeed;
    MockUniswapV2Router public uniswapRouter;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // could just Lending.CONSTANTNAME but this just adjustable
    uint256 public constant PRICE_STALE_TIME = 24 hours;
    uint256 public constant INITIAL_INTEREST_RATE = 500; // 5% in BPS
    uint256 public constant LTV_BPS = 7000; // 70% LTV in BPS
    uint16 public constant HEALTH_FACTOR_THRESHOLD_BPS = 10_000; // 100%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_PRECISION = 1e18; // Used for inverse price calculations
    int256 public constant PRICE_1 = 2000 * 1e8; // $2000 with 8 decimals
    int256 public constant PRICE_2 = 1 * 1e8; // $1 with 8 decimals
    int256 public constant IDRX_USD_PRICE = 6050; // $0.0000605 with 8 decimals

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

        // Deploy mock uniswap
        uniswapRouter = new MockUniswapV2Router();

        // Deploy lending contract
        lending = new Lending(owner, address(debtToken), address(debtTokenPriceFeed), address(uniswapRouter));

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
        vm.expectRevert(Lending.Lending__TokenNotSupported.selector);
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

        Lending.Loan memory loan = lending.getLoanInfo();
        vm.stopPrank();

        assertEq(loan.debt - loan.repaid, loan.debt - repayAmount);
        assertEq(loan.repaid, repayAmount);
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

        uint256 debt = lending.getLoanInfo().debt;
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

        uint256 debt = lending.getLoanInfo().debt;
        debtToken.approve(address(lending), debt);
        vm.stopPrank();

        // assuming user1 get debtToken from external source
        vm.startPrank(owner);
        debtToken.mint(user1, 100_000_000e18); // just random big value but can also use existing variable
        vm.stopPrank();

        vm.startPrank(user1, user1);
        lending.repayLoan(debt);
        vm.stopPrank();

        vm.startPrank(user1);
        Lending.Loan memory loan = lending.getLoanInfo();
        vm.stopPrank();

        assertEq(loan.debt, 0);
        assertEq(loan.repaid, 0);
    }

    // ============ Start Collateral Raising Tests ============
    function test_startCollateralRaising() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500; // 5%

        vm.startPrank(user1, user1);
        vm.expectEmit(true, true, true, true);
        emit Lending.RaisingCollateral(user1, address(collateralToken1), targetAmount, interestRate);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        (
            bool isOpen,
            address collateral,
            uint256 target,
            uint256 repaid,
            uint256 interestRateBPS,
            address[] memory funders,
        ) = lending.getUserCollateralRaisingInfo(user1);
        assertTrue(isOpen);
        assertEq(collateral, address(collateralToken1));
        assertEq(target, targetAmount);
        assertEq(repaid, 0);
        assertEq(interestRateBPS, interestRate);
        assertEq(funders.length, 0);
    }

    function test_startCollateralRaising_RevertIfAlreadyOpen() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500;

        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.expectRevert(Lending.Lending__CollateralRaisingAlreadyOpen.selector);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();
    }

    function test_startCollateralRaising_RevertIfUnsupportedToken() public {
        ERC20Mock unsupportedToken = new ERC20Mock();
        vm.startPrank(user1, user1);
        vm.expectRevert(Lending.Lending__TokenNotSupported.selector);
        lending.startCollateralRaising(address(unsupportedToken), 1e18, 500);
        vm.stopPrank();
    }

    // ============ Fund User Tests ============
    function test_fundUser() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500;
        uint256 fundAmount = 0.5e18;

        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        vm.startPrank(user2, user2);
        collateralToken1.approve(address(lending), fundAmount);
        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralFunded(user1, user2, fundAmount);
        lending.fundUser(user1, fundAmount);
        vm.stopPrank();

        (,,, uint256 raised,, address[] memory funders, Lending.FunderInfo[] memory funderInfo) =
            lending.getUserCollateralRaisingInfo(user1);
        assertEq(raised, fundAmount);
        assertEq(funders.length, 1);
        assertEq(funderInfo[0].amount, fundAmount);
    }

    // ============ Close Collateral Raising Tests ============
    function test_closeCollateralRaising() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500;

        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        vm.startPrank(user2, user2);
        collateralToken1.approve(address(lending), targetAmount);
        lending.fundUser(user1, targetAmount);
        vm.stopPrank();

        vm.startPrank(user1, user1);
        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralRaisingClosed(user1);
        lending.closeCollateralRaising();

        uint256 userTokenBalance = lending.getCollateralBalance(address(collateralToken1));
        vm.stopPrank();

        (bool isOpen,,,,,,) = lending.getUserCollateralRaisingInfo(user1);
        assertFalse(isOpen);
        assertEq(userTokenBalance, targetAmount);
    }

    function test_closeCollateralRaising_CanCloseIfOwnCCollateralRaising() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500;

        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        lending.closeCollateralRaising(); // Try to close without funding
        vm.stopPrank();

        (bool open,,,,,,) = lending.getUserCollateralRaisingInfo(user1);
        assertFalse(open);
    }

    // ============ Repay Funder Collateral Tests ============
    function test_repayFunder() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500; // 5%
        uint256 fundAmount = 0.5e18;

        // Setup raising
        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        // Fund
        vm.startPrank(user2, user2);
        collateralToken1.approve(address(lending), fundAmount);
        lending.fundUser(user1, fundAmount);
        vm.stopPrank();

        // Close raising
        vm.startPrank(user1, user1); // using user1 to bypass target check
        lending.closeCollateralRaising();
        vm.stopPrank();

        // Repay
        uint256 collateralRepay = fundAmount / 2; // repay half
        uint256 tokenValueInDebtToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 totalTokenValueInDebtToken = PriceFeedLib.getTokenTotalPrice(tokenValueInDebtToken, fundAmount);
        uint256 totalInterest = ((totalTokenValueInDebtToken * interestRate) / BPS_DENOMINATOR);
        uint256 interestRepay = totalInterest / 2; // repay half

        // simulate user1 had debtToken balance to pay
        vm.startPrank(owner);
        debtToken.mint(user1, totalInterest);
        vm.stopPrank();

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), collateralRepay);
        debtToken.approve(address(lending), interestRepay);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralRepayment(user1, user2, collateralRepay);
        vm.expectEmit(true, true, true, true);
        emit Lending.InterestPaid(user1, user2, interestRepay);
        lending.repayFunder(user2, collateralRepay, interestRepay);
        vm.stopPrank();

        (,,,,,, Lending.FunderInfo[] memory funderInfo) = lending.getUserCollateralRaisingInfo(user1);

        assertEq(funderInfo[0].amount, fundAmount - collateralRepay);
        assertEq(funderInfo[0].reward, totalInterest - interestRepay);
    }

    function test_repayFunder_CollateralOnly() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500; // 5%
        uint256 fundAmount = 0.5e18;

        // Setup raising
        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        // Fund
        vm.startPrank(user2, user2);
        collateralToken1.approve(address(lending), fundAmount);
        lending.fundUser(user1, fundAmount);
        vm.stopPrank();

        // Close raising
        vm.startPrank(user1, user1); // using user1 to bypass target check
        lending.closeCollateralRaising();
        vm.stopPrank();

        // Repay
        uint256 collateralRepay = fundAmount / 2; // repay half

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), collateralRepay);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralRepayment(user1, user2, collateralRepay);
        lending.repayFunder(user2, collateralRepay, 0);
        vm.stopPrank();

        (,,,,,, Lending.FunderInfo[] memory funderInfo) = lending.getUserCollateralRaisingInfo(user1);

        assertEq(funderInfo[0].amount, fundAmount - collateralRepay);
    }

    function test_repayFunder_InterestOnly() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500; // 5%
        uint256 fundAmount = 0.5e18;

        // Setup raising
        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        // Fund
        vm.startPrank(user2, user2);
        collateralToken1.approve(address(lending), fundAmount);
        lending.fundUser(user1, fundAmount);
        vm.stopPrank();

        // Close raising
        vm.startPrank(user1, user1); // using user1 to bypass target check
        lending.closeCollateralRaising();
        vm.stopPrank();

        // Repay
        uint256 tokenValueInDebtToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 totalTokenValueInDebtToken = PriceFeedLib.getTokenTotalPrice(tokenValueInDebtToken, fundAmount);
        uint256 totalInterest = ((totalTokenValueInDebtToken * interestRate) / BPS_DENOMINATOR);
        uint256 interestRepay = totalInterest / 2; // repay half

        // simulate user1 had debtToken balance to pay
        vm.startPrank(owner);
        debtToken.mint(user1, totalInterest);
        vm.stopPrank();

        vm.startPrank(user1);
        debtToken.approve(address(lending), interestRepay);

        vm.expectEmit(true, true, true, true);
        emit Lending.InterestPaid(user1, user2, interestRepay);
        lending.repayFunder(user2, 0, interestRepay);
        vm.stopPrank();

        (,,,,,, Lending.FunderInfo[] memory funderInfo) = lending.getUserCollateralRaisingInfo(user1);

        assertEq(funderInfo[0].amount, fundAmount);
        assertEq(funderInfo[0].reward, totalInterest - interestRepay);
    }

    function test_repayFunder_RevertIfBothZero() public {
        vm.startPrank(user1, user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.repayFunder(user2, 0, 0);
        vm.stopPrank();
    }

    // ============ Liquidate Tests ============
    // function test_liquidate() public {
    //     // 1. Setup - User deposits collateral and takes loan
    //     uint256 depositAmount = 1 ether; // 1e18 tokens
    //     vm.startPrank(user1);
    //     collateralToken1.approve(address(lending), depositAmount);
    //     lending.depositCollateral(address(collateralToken1), depositAmount);

    //     // Borrow 50% of collateral value
    //     uint256 borrowAmount = lending.getTotalCollateralValueInDebtToken(user1) / 2;
    //     lending.takeLoan(borrowAmount);
    //     vm.stopPrank();

    //     // 2. Simulate price drop to trigger liquidation
    //     // Original price: $2000, New price: $500 (75% drop)
    //     priceFeed1.updateAnswer(500e8);

    //     // 3. Calculate expected liquidation amounts
    //     uint256 totalDebt = lending.getLoanInfo().debt; // No repayments yet
    //     uint256 liquidationAmount = totalDebt * (10_000 + 1_000) / 10_000; // Debt + 10% penalty

    //     // Convert liquidation amount to collateral tokens
    //     uint256 collateralPriceInDebtTokens = PriceFeedLib.convertPriceToTokenAmount(
    //         address(priceFeed1),
    //         address(debtTokenPriceFeed),
    //         lending.PRICE_STALE_TIME()
    //     );
    //     uint256 expectedSeized = (liquidationAmount * 1e18) / collateralPriceInDebtTokens;

    //     // 4. Setup Uniswap for the swap
    //     uniswapRouter.setMockRate(
    //         address(collateralToken1),
    //         address(debtToken),
    //         collateralPriceInDebtTokens
    //     );
    //     uniswapRouter.setMockReserves(address(collateralToken1), address(debtToken), 100_000 ether, 100_000 ether);

    //     // 5. Execute liquidation
    //     vm.startPrank(user2);
    //     vm.expectEmit(true, true, true, true);
    //     emit Lending.Liquidated(user1, address(collateralToken1), expectedSeized);
    //     lending.liquidate(user1, address(collateralToken1));
    //     vm.stopPrank();

    //     // 6. Verify results
    //     Lending.Loan memory loan = lending.getLoanInfo();
    //     uint256 remainingCollateral = lending.getCollateralBalance(user1, address(collateralToken1));

    //     assertEq(loan.debt, 0, "Debt should be cleared");
    //     assertEq(remainingCollateral, depositAmount - expectedSeized, "Correct collateral seized");
    // }

    function test_liquidate_RevertIfHealthyPosition() public {
        uint256 depositAmount = 1e18;

        // Setup collateral and loan
        vm.startPrank(user1, user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        vm.stopPrank();

        // Check initial collateral value
        uint256 collateralValue = lending.getTotalCollateralValueInDebtToken(user1);
        uint256 borrowAmount = collateralValue / 2; // Conservative LTV (50%)

        // Take loan
        vm.startPrank(user1, user1);
        lending.takeLoan(borrowAmount);
        Lending.Loan memory loan = lending.getLoanInfo();
        vm.stopPrank();

        // Verify health factor is healthy
        uint256 healthFactor =
            (collateralValue * LTV_BPS * HEALTH_FACTOR_THRESHOLD_BPS) / (borrowAmount * BPS_DENOMINATOR);

        assertGt(healthFactor, lending.HEALTH_FACTOR_THRESHOLD_BPS(), "Position should be healthy");

        // Verify loan is not overdue
        assertLt(block.timestamp, loan.dueDate, "Loan should not be overdue");

        // Setup Uniswap mock (even though we expect revert)
        uniswapRouter.setMockRate(
            address(collateralToken1),
            address(debtToken),
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME)
        );
        uniswapRouter.setMockReserves(address(collateralToken1), address(debtToken), 1000e18, 1000e18);

        // Attempt liquidation (should revert)
        vm.startPrank(user2, user2);
        vm.expectRevert(Lending.Lending__NotLiquidatable.selector);
        lending.liquidate(user1, address(collateralToken1));
        vm.stopPrank();

        // Additional checks to ensure state unchanged
        vm.startPrank(user1);
        uint256 user1CollateralBalance = lending.getCollateralBalance(address(collateralToken1));
        Lending.Loan memory postLoan = lending.getLoanInfo();
        vm.stopPrank();
        assertEq(postLoan.debt, loan.debt, "Debt should not change");
        assertEq(user1CollateralBalance, depositAmount, "Collateral should not be seized");
    }

    // ============ Admin Function Tests ============
    function test_depositDebtToken() public {
        uint256 amount = 1000e18;
        uint256 initialBalance = debtToken.balanceOf(address(lending));

        vm.startPrank(owner);
        debtToken.mint(owner, 2000e18);
        debtToken.approve(address(lending), amount);
        lending.depositDebtToken(amount);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(address(lending)), initialBalance + amount);
    }

    function test_withdrawDebtToken() public {
        uint256 amount = 1000e18;
        uint256 initialOwnerBalance = debtToken.balanceOf(owner);

        vm.startPrank(owner);
        lending.withdrawDebtToken(amount);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(owner), initialOwnerBalance + amount);
    }

    function test_withdrawDebtToken_RevertIfInsufficientBalance() public {
        uint256 balance = debtToken.balanceOf(address(lending));

        vm.startPrank(owner);
        vm.expectRevert(Lending.Lending__InsufficientLiquidity.selector);
        lending.withdrawDebtToken(balance + 1);
        vm.stopPrank();
    }

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
    function test_getTotalCollateralValueInDebtToken() public {
        uint256 depositAmount1 = 1e18;
        uint256 depositAmount2 = 100e6; // 100 tokens with 6 decimals

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount1);
        collateralToken2.approve(address(lending), depositAmount2);
        lending.depositCollateral(address(collateralToken1), depositAmount1);
        lending.depositCollateral(address(collateralToken2), depositAmount2);
        vm.stopPrank();

        uint256 token1ValueInDebtToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed1), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 token2ValueInDebtToken =
            PriceFeedLib.convertPriceToTokenAmount(address(priceFeed2), address(debtTokenPriceFeed), PRICE_STALE_TIME);
        uint256 expectedValue = PriceFeedLib.getTokenTotalPrice(token1ValueInDebtToken, depositAmount1)
            + PriceFeedLib.getTokenTotalPrice(token2ValueInDebtToken, depositAmount2);

        assertEq(lending.getTotalCollateralValueInDebtToken(user1), expectedValue);
    }

    function test_getCollateralTokens() public view {
        address[] memory tokens = lending.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(collateralToken1));
        assertEq(tokens[1], address(collateralToken2));
    }

    function test_getCollateralBalance() public {
        uint256 depositAmount = 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 userTokenBalance = lending.getCollateralBalance(address(collateralToken1));
        vm.stopPrank();

        assertEq(userTokenBalance, depositAmount);
    }

    function test_getCollateralRaisingDetails() public {
        uint256 targetAmount = 1e18;
        uint16 interestRate = 500;

        vm.startPrank(user1, user1);
        lending.startCollateralRaising(address(collateralToken1), targetAmount, interestRate);
        vm.stopPrank();

        (bool isOpen, address token, uint256 target,, uint256 rate,,) = lending.getUserCollateralRaisingInfo(user1);
        assertTrue(isOpen);
        assertEq(token, address(collateralToken1));
        assertEq(target, targetAmount);
        assertEq(rate, interestRate);
    }
}
