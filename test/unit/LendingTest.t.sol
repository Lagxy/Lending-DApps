// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {Lending} from "../../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MockAggregatorV3Interface} from "../mocks/MockAggregatorV3Interface.sol";
import {MockUniswapV2Router} from "../mocks/MockUniswapV2Router.sol";
import {PriceFeedLib} from "../../src/libs/PriceFeedLib.sol";

contract LendingTest is Test {
    Lending public lending;
    MockERC20 public debtToken;
    MockERC20 public collateralToken1;
    MockERC20 public collateralToken2;
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
    uint8 public constant TOKEN1_DECIMALS = 18;
    uint8 public constant TOKEN2_DECIMALS = 24;
    uint8 public constant IDRX_DECIMALS = 2;
    uint8 public constant DEFAULT_DECIMALS = 18;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock tokens
        debtToken = new MockERC20("debtToken", "dt", 200_000_000_000 * (10 ** IDRX_DECIMALS), IDRX_DECIMALS);
        collateralToken1 = new MockERC20("token1", "t1", 100_000_000_000 * (10 ** TOKEN1_DECIMALS), TOKEN1_DECIMALS);
        collateralToken2 = new MockERC20("token2", "t2", 100_000_000_000 * (10 ** TOKEN2_DECIMALS), TOKEN2_DECIMALS);

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
        collateralToken2.mint(user1, 10_000 * 1e24);
        collateralToken2.mint(user2, 10_000 * 1e24);

        vm.stopPrank();
    }

    // Helper function
    function _normalizeAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else if (fromDecimals < toDecimals) {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
        return amount;
    }

    // ============ Deposit Collateral Tests ============
    function test_depositCollateral() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);

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
        MockERC20 unsupportedToken = new MockERC20("", "", 0, 0);

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

        uint256 maxBorrow = lending.getTotalCollateralValueInDebtToken(user1);
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

        uint256 maxBorrow = lending.getTotalCollateralValueInDebtToken(user1);
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

        uint256 maxBorrow = lending.getTotalCollateralValueInDebtToken(user1);
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

        uint256 maxBorrow = lending.getTotalCollateralValueInDebtToken(user1);
        uint256 borrowAmount = maxBorrow / 4; // Borrow 1/4 of max
        uint256 repayAmount = borrowAmount / 2; // try to repay half borrow amount

        lending.takeLoan(borrowAmount);

        debtToken.approve(address(lending), repayAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.Repaid(user1, repayAmount);
        lending.repayLoan(repayAmount);

        Lending.Loan memory loan = lending.getLoanInfo(user1);
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

        uint256 maxBorrow = lending.getTotalCollateralValueInDebtToken(user1);
        uint256 borrowAmount = maxBorrow / 4; // Borrow 1/4 of max

        lending.takeLoan(borrowAmount);

        uint256 debt = lending.getLoanInfo(user1).debt;
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

        uint256 maxBorrow = lending.getTotalCollateralValueInDebtToken(user1);
        uint256 borrowAmount = maxBorrow / 4; // Borrow 1/4 of max

        lending.takeLoan(borrowAmount);

        uint256 debt = lending.getLoanInfo(user1).debt;
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
        Lending.Loan memory loan = lending.getLoanInfo(user1);
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
        MockERC20 unsupportedToken = new MockERC20("", "", 0, 0);
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

        uint256 totalTokenValueInDebtToken =
            PriceFeedLib.getTokenTotalPrice(tokenValueInDebtToken, fundAmount, DEFAULT_DECIMALS, TOKEN1_DECIMALS);

        uint256 totalInterest = _normalizeAmount(
            ((totalTokenValueInDebtToken * interestRate) / BPS_DENOMINATOR), DEFAULT_DECIMALS, IDRX_DECIMALS
        );
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
        uint256 totalTokenValueInDebtToken =
            PriceFeedLib.getTokenTotalPrice(tokenValueInDebtToken, fundAmount, DEFAULT_DECIMALS, TOKEN1_DECIMALS);
        uint256 totalInterest = _normalizeAmount(
            ((totalTokenValueInDebtToken * interestRate) / BPS_DENOMINATOR), DEFAULT_DECIMALS, IDRX_DECIMALS
        );
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

    // only works if set the uniswap transfer normalized to 2 decimal or make idrx to 18 decimals
    // ============ Liquidate Tests ============
    function test_liquidate() public {
        uint256 depositAmount = 100e24; // $100

        vm.startPrank(user1, user1);
        collateralToken2.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken2), depositAmount);

        uint256 borrowAmount = lending.getTotalCollateralValueInDebtToken(user1) / 2; // borrow half
        lending.takeLoan(borrowAmount);

        // Simulate price drop to trigger liquidation
        // Original price: $1, New price: $0.6 (50% drop)
        priceFeed2.updateAnswer(5e7);

        // 3. Calculate expected liquidation amounts
        uint256 totalDebt = lending.getLoanInfo(user1).debt; // No repayments yet
        uint256 liquidationAmount = totalDebt * (BPS_DENOMINATOR + 1_000) / BPS_DENOMINATOR; // Debt + 10% penalty
        vm.stopPrank();

        // Convert liquidation amount to collateral tokens
        uint256 collateralPriceInDebtTokens = PriceFeedLib.convertPriceToTokenAmount(
            address(priceFeed2), address(debtTokenPriceFeed), lending.PRICE_STALE_TIME()
        );

        uint256 expectedSeized = (liquidationAmount * PRICE_PRECISION) / collateralPriceInDebtTokens;
        uint256 expectedSeizedNormalized = _normalizeAmount(expectedSeized, DEFAULT_DECIMALS, TOKEN2_DECIMALS);

        // 4. Setup Uniswap for the swap
        uint256 debtTokenReserve = 10_000_000_000 * (10 ** IDRX_DECIMALS); // debt token
        uint256 collateralReserve = 100_000 * (10 ** TOKEN2_DECIMALS); // collateral token

        console.log("(test) collateralPriceInDebtTokens: ", collateralPriceInDebtTokens);

        vm.startPrank(owner);
        uniswapRouter.setMockRate(address(collateralToken2), address(debtToken), collateralPriceInDebtTokens);

        debtToken.approve(address(uniswapRouter), type(uint256).max);
        collateralToken2.approve(address(uniswapRouter), type(uint256).max);

        uniswapRouter.addLiquidity(address(collateralToken2), address(debtToken), collateralReserve, debtTokenReserve);
        vm.stopPrank();

        // Condition before liquidate
        // protocol balance should increase
        uint256 protocolOldBalance = IERC20(debtToken).balanceOf(address(lending));
        // user collateral should seized
        vm.startPrank(user1);
        uint256 userCollateral = lending.getCollateralBalance(address(collateralToken2));
        // user debt should cleared/repaid
        Lending.Loan memory oldLoan = lending.getLoanInfo(user1);
        vm.stopPrank();

        // 5. Execute liquidation
        vm.startPrank(user2, user2);
        lending.liquidate(user1, address(collateralToken2));
        console.log("expectedSeizedNormalized: ", expectedSeizedNormalized);
        vm.stopPrank();

        // 6. Verify results
        uint256 protocolNewBalance = IERC20(debtToken).balanceOf(address(lending));

        vm.startPrank(user1);
        Lending.Loan memory newLoan = lending.getLoanInfo(user1);
        uint256 remainingCollateral = lending.getCollateralBalance(address(collateralToken2));
        vm.stopPrank();

        // rough test
        assertGt(protocolNewBalance, protocolOldBalance, "balance should increase");
        assertLt(remainingCollateral, userCollateral);
        assertGt(newLoan.repaid, oldLoan.repaid);
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
        MockERC20 newToken = new MockERC20("", "", 0, 0);
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
        uint256 depositAmount1 = 1e18; // 1 token
        uint256 depositAmount2 = 100e23; // 0.1 token

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

        uint256 expectedValue = PriceFeedLib.getTokenTotalPrice(
            token1ValueInDebtToken, depositAmount1, DEFAULT_DECIMALS, TOKEN1_DECIMALS
        ) + PriceFeedLib.getTokenTotalPrice(token2ValueInDebtToken, depositAmount2, DEFAULT_DECIMALS, TOKEN2_DECIMALS);
        uint256 expectedValueNormalized = _normalizeAmount(expectedValue, DEFAULT_DECIMALS, IDRX_DECIMALS);

        assertEq(lending.getTotalCollateralValueInDebtToken(user1) + 1, expectedValueNormalized); // idrx decimal too small, causing precision loss
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
