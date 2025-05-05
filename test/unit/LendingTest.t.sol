// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {Lending} from "../../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract LendingTest is Test {
    Lending public lending;
    ERC20Mock public debtToken;
    ERC20Mock public collateralToken1;
    ERC20Mock public collateralToken2;
    MockV3Aggregator public priceFeed1;
    MockV3Aggregator public priceFeed2;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 public constant INITIAL_INTEREST_RATE = 500; // 5% in BPS
    uint256 public constant LTV = 75; // 75% LTV
    uint256 public constant CLOSE_FACTOR = 0.5e18; // 50% of debt can be liquidated at once
    uint256 public constant LIQUIDATION_BONUS = 1.1e18; // 10% liquidation bonus
    uint256 private constant PRICE_PRECISION = 1e36; // Used for inverse price calculations
    int256 public constant PRICE_1 = 2000 * 1e8; // $2000 with 8 decimals
    int256 public constant PRICE_2 = 1 * 1e8; // $1 with 8 decimals

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock tokens
        debtToken = new ERC20Mock();
        collateralToken1 = new ERC20Mock();
        collateralToken2 = new ERC20Mock();

        // Deploy mock price feeds with int256 prices
        priceFeed1 = new MockV3Aggregator(8, PRICE_1);
        priceFeed2 = new MockV3Aggregator(8, PRICE_2);

        // Deploy lending contract
        lending = new Lending(owner, address(debtToken));

        // Add collateral tokens
        lending.addCollateralToken(address(collateralToken1), address(priceFeed1));
        lending.addCollateralToken(address(collateralToken2), address(priceFeed2));

        // Set initial interest rate
        lending.setInterestRate(INITIAL_INTEREST_RATE);

        // Mint tokens to users
        debtToken.mint(address(lending), 100_000 * 1e18);
        collateralToken1.mint(user1, 10 * 1e18);
        collateralToken1.mint(user2, 10 * 1e18);
        collateralToken2.mint(user1, 10_000 * 1e6);
        collateralToken2.mint(user2, 10_000 * 1e6);

        vm.stopPrank();
    }

    // ============ Price Feed Tests ============
    function test_GetTokenPrice() public view {
        uint256 price = lending.getTokenPrice(address(collateralToken1));
        assertEq(price, uint256(PRICE_1) * 1e10); // Convert 8 decimals to 18
    }

    function test_GetTokenPrice_RevertIfStalePrice() public {
        // Fast forward time to make price stale
        vm.warp(block.timestamp + 86400 + 1); // 24 hours + 1 second

        vm.expectRevert(Lending.Lending__StalePriceData.selector);
        lending.getTokenPrice(address(collateralToken1));
    }

    function test_GetTokenPrice_RevertIfInvalidPrice() public {
        // Set price to zero
        priceFeed1.updateAnswer(0);

        vm.expectRevert(Lending.Lending__InvalidPriceFeed.selector);
        lending.getTokenPrice(address(collateralToken1));
    }

    function test_GetTokenPrice_RevertIfNegativePrice() public {
        // Set negative price
        priceFeed1.updateAnswer(-100);

        vm.expectRevert(Lending.Lending__InvalidPriceFeed.selector);
        lending.getTokenPrice(address(collateralToken1));
    }

    // ============ Deposit Collateral Tests ============
    function test_DepositCollateral() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralDeposited(user1, address(collateralToken1), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        vm.stopPrank();

        assertEq(lending.getCollateralBalance(user1, address(collateralToken1)), depositAmount);
        assertEq(collateralToken1.balanceOf(user1), 10 * 1e18 - depositAmount);
    }

    function test_DepositCollateral_RevertIfAmountZero() public {
        vm.startPrank(user1);
        collateralToken1.approve(address(lending), 1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.depositCollateral(address(collateralToken1), 0);
        vm.stopPrank();
    }

    function test_DepositCollateral_RevertIfTokenNotSupported() public {
        ERC20Mock unsupportedToken = new ERC20Mock();

        vm.startPrank(user1);
        unsupportedToken.approve(address(lending), 1);
        vm.expectRevert(Lending.Lending__TokenNotSupported.selector);
        lending.depositCollateral(address(unsupportedToken), 1);
        vm.stopPrank();
    }

    // ============ Borrow Tests ============
    function test_Borrow() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 expectedCollateralValue = lending.getTokenPrice(address(collateralToken1));
        uint256 maxBorrow = (expectedCollateralValue * LTV) / 100;
        uint256 borrowAmount = maxBorrow / 2; // Borrow half of max

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        uint256 expectedDebt = borrowAmount + ((borrowAmount * INITIAL_INTEREST_RATE) / 10000);

        vm.expectEmit(true, true, true, true);
        emit Lending.Borrowed(user1, borrowAmount, expectedDebt);
        lending.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(user1), borrowAmount);
        assertEq(lending.getLoanDebtAmount(user1), expectedDebt);
        assertEq(lending.getLoanRemainingDebt(user1), expectedDebt);
    }

    function test_Borrow_RevertIfAmountZero() public {
        vm.startPrank(user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.borrow(0);
        vm.stopPrank();
    }

    function test_Borrow_RevertIfExistingDebt() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 borrowAmount = 100 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        lending.borrow(borrowAmount);

        vm.expectRevert(Lending.Lending__DebtNotZero.selector);
        lending.borrow(borrowAmount);
        vm.stopPrank();
    }

    function test_Borrow_RevertIfExceedsLTV() public {
        uint256 depositAmount = 1 * 1e18;
        // uint256 expectedCollateralValue = _calculateCollateralValue(depositAmount, PRICE_1, 18);
        // uint256 maxBorrow = (expectedCollateralValue * LTV) / 100;
        // uint256 borrowAmount = maxBorrow + 1; // Exceeds LTV

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        // Does not follow AAA (Arrange, Act, Assert) Pattern
        uint256 collateralValue = lending.getTotalCollateralValue(user1);
        uint256 maxBorrow = (collateralValue * LTV) / 100;
        uint256 borrowAmount = maxBorrow + 1; // Exceeds LTV

        vm.expectRevert(Lending.Lending__AmountExceeds.selector);
        lending.borrow(borrowAmount);
        vm.stopPrank();
    }

    // ============ Repay Tests ============
    function test_Repay() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 borrowAmount = 100 * 1e18;
        uint256 repayAmount = 50 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        lending.borrow(borrowAmount);

        debtToken.approve(address(lending), repayAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.Repaid(user1, repayAmount);
        lending.repay(repayAmount);
        vm.stopPrank();

        uint256 totalDebt = lending.getLoanDebtAmount(user1);
        assertEq(lending.getLoanRemainingDebt(user1), totalDebt - repayAmount);
        assertEq(lending.getLoanRepaidAmount(user1), repayAmount);
    }

    function test_Repay_RevertIfAmountZero() public {
        vm.startPrank(user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.repay(0);
        vm.stopPrank();
    }

    function test_Repay_RevertIfAmountExceedsDebt() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 borrowAmount = 100 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        lending.borrow(borrowAmount);

        uint256 totalDebt = lending.getLoanDebtAmount(user1);
        debtToken.approve(address(lending), totalDebt + 1);

        vm.expectRevert(Lending.Lending__AmountExceeds.selector);
        lending.repay(totalDebt + 1);
        vm.stopPrank();
    }

    function test_Repay_FullRepaymentResetsDebt() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 borrowAmount = 100 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        lending.borrow(borrowAmount);

        uint256 totalDebt = lending.getLoanDebtAmount(user1);
        debtToken.approve(address(lending), totalDebt);
        vm.stopPrank();

        // assuming user1 get debtToken from external source
        vm.startPrank(owner);
        debtToken.mint(user1, 100_000e18);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit Lending.DebtResetted(user1);
        lending.repay(totalDebt);
        vm.stopPrank();

        assertEq(lending.getLoanRemainingDebt(user1), 0);
        assertEq(lending.getLoanDebtAmount(user1), 0);
        assertEq(lending.getLoanRepaidAmount(user1), 0);
    }

    // ============ Withdraw Collateral Tests ============
    function test_WithdrawCollateral() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 withdrawAmount = 0.5 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralWithdrawn(user1, address(collateralToken1), withdrawAmount);
        lending.withdrawCollateral(address(collateralToken1), withdrawAmount);
        vm.stopPrank();

        assertEq(lending.getCollateralBalance(user1, address(collateralToken1)), depositAmount - withdrawAmount);
        assertEq(collateralToken1.balanceOf(user1), 10 * 1e18 - depositAmount + withdrawAmount);
    }

    function test_WithdrawCollateral_RevertIfAmountZero() public {
        vm.startPrank(user1);
        vm.expectRevert(Lending.Lending__MustBeMoreThanZero.selector);
        lending.withdrawCollateral(address(collateralToken1), 0);
        vm.stopPrank();
    }

    function test_WithdrawCollateral_RevertIfInsufficientCollateral() public {
        uint256 depositAmount = 1 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);

        vm.expectRevert(Lending.Lending__InsufficientCollateral.selector);
        lending.withdrawCollateral(address(collateralToken1), depositAmount + 1);
        vm.stopPrank();
    }

    function test_WithdrawCollateral_RevertIfDebtNotZero() public {
        uint256 depositAmount = 1 * 1e18;
        uint256 borrowAmount = 100 * 1e18;

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount);
        lending.depositCollateral(address(collateralToken1), depositAmount);
        lending.borrow(borrowAmount);

        vm.expectRevert(Lending.Lending__DebtNotZero.selector);
        lending.withdrawCollateral(address(collateralToken1), depositAmount);
        vm.stopPrank();
    }

    // ============ Liquidate Tests ============
    // function test_Liquidate() public {
    //     uint256 depositAmount = 1 * 1e18;
    //     uint256 borrowAmount = 150 * 1e18; // Will exceed LTV after price drop

    //     // Setup user1 with collateral and debt
    //     vm.startPrank(user1);
    //     collateralToken1.approve(address(lending), depositAmount);
    //     lending.depositCollateral(address(collateralToken1), depositAmount);
    //     lending.borrow(borrowAmount);
    //     vm.stopPrank();

    //     // Simulate price drop
    //     int256 newPrice = PRICE_1 / 2;
    //     priceFeed1.updateAnswer(newPrice);

    //     // Get debt before liquidation
    //     uint256 debtBefore = lending.getLoanRemainingDebt(user1);
    //     uint256 maxDebtToCover = (debtBefore * CLOSE_FACTOR) / 1e18;

    //     // Calculate expected collateral to seize (including bonus)
    //     uint256 tokenPrice = lending.getTokenPrice(address(collateralToken1));
    //     uint256 inversePriceWithBonus = (PRICE_PRECISION * LIQUIDATION_BONUS) / tokenPrice;
    //     uint256 expectedCollateralToSeize = (maxDebtToCover * inversePriceWithBonus) / 1e18;

    //     // Approve and liquidate
    //     vm.startPrank(user2);
    //     debtToken.approve(address(lending), maxDebtToCover);

    //     // Expect the correct event emission
    //     vm.expectEmit(true, true, true, true);
    //     emit Lending.Liquidated(user1, address(collateralToken1), maxDebtToCover, expectedCollateralToSeize);

    //     lending.liquidate(
    //         user1,
    //         address(collateralToken1),
    //         maxDebtToCover,
    //         0,
    //         block.timestamp + 1 hours
    //     );
    //     vm.stopPrank();

    //     // Check debt reduction and collateral transfer
    //     assertLt(lending.getLoanRemainingDebt(user1), debtBefore);
    //     assertGt(collateralToken1.balanceOf(user2), 0);
    //     // check the amount of collateral transferred
    //     assertEq(collateralToken1.balanceOf(user2), expectedCollateralToSeize);
    // }

    // function test_Liquidate_RevertIfLTVNotViolated() public {
    //     uint256 depositAmount = 1 * 1e18;
    //     uint256 borrowAmount = 100 * 1e18; // Within LTV

    //     vm.startPrank(user1);
    //     collateralToken1.approve(address(lending), depositAmount);
    //     lending.depositCollateral(address(collateralToken1), depositAmount);
    //     lending.borrow(borrowAmount);
    //     vm.stopPrank();

    //     // Still healthy, should revert
    //     uint256 debt = lending.getLoanRemainingDebt(user1);
    //     uint256 maxDebtToCover = (debt * CLOSE_FACTOR) / 1e18;

    //     vm.startPrank(user2);
    //     debtToken.approve(address(lending), maxDebtToCover);
    //     vm.expectRevert(Lending.Lending__NotLiquidatable.selector);
    //     lending.liquidate(
    //         user1,
    //         address(collateralToken1),
    //         maxDebtToCover,
    //         0,
    //         block.timestamp + 1 hours
    //     );
    //     vm.stopPrank();
    // }

    // ============ Admin Function Tests ============
    function test_AddCollateralToken() public {
        ERC20Mock newToken = new ERC20Mock();
        MockV3Aggregator newPriceFeed = new MockV3Aggregator(8, PRICE_1);

        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralTokenAdded(address(newToken), address(newPriceFeed));
        lending.addCollateralToken(address(newToken), address(newPriceFeed));

        assertTrue(lending.isCollateralSupported(address(newToken)));
        assertEq(lending.getPriceFeed(address(newToken)), address(newPriceFeed));
    }

    function test_AddCollateralToken_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.addCollateralToken(address(collateralToken1), address(priceFeed1));
    }

    function test_AddCollateralToken_RevertIfMaxTokensReached() public {
        // First fill up the collateral tokens array
        vm.startPrank(owner);
        for (uint256 i = 2; i < 50; i++) {
            ERC20Mock token = new ERC20Mock();
            MockV3Aggregator feed = new MockV3Aggregator(8, PRICE_1);
            lending.addCollateralToken(address(token), address(feed));
        }

        // Try to add one more
        ERC20Mock newToken = new ERC20Mock();
        MockV3Aggregator newPriceFeed = new MockV3Aggregator(8, PRICE_1);

        vm.expectRevert(Lending.Lending__MaxTokensReached.selector);
        lending.addCollateralToken(address(newToken), address(newPriceFeed));
        vm.stopPrank();
    }

    function test_UpdatePriceFeed() public {
        MockV3Aggregator newPriceFeed = new MockV3Aggregator(8, PRICE_2);

        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.PriceFeedUpdated(address(collateralToken1), address(newPriceFeed));
        lending.updatePriceFeed(address(collateralToken1), address(newPriceFeed));

        assertEq(lending.getPriceFeed(address(collateralToken1)), address(newPriceFeed));
    }

    function test_UpdatePriceFeed_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.updatePriceFeed(address(collateralToken1), address(priceFeed1));
    }

    function test_RemoveCollateralToken() public {
        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.CollateralTokenRemoved(address(collateralToken1));
        lending.removeCollateralToken(address(collateralToken1));

        assertFalse(lending.isCollateralSupported(address(collateralToken1)));
    }

    function test_RemoveCollateralToken_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.removeCollateralToken(address(collateralToken1));
    }

    function test_SetInterestRate() public {
        uint256 newRate = 1000; // 10%

        vm.prank(owner);

        vm.expectEmit(true, true, true, true);
        emit Lending.InterestRateChanged(newRate);
        lending.setInterestRate(newRate);

        assertEq(lending.getLoanInterestRate(), newRate);
    }

    function test_SetInterestRate_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.setInterestRate(1000);
    }

    function test_SetInterestRate_RevertIfExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(Lending.Lending__AmountExceeds.selector);
        lending.setInterestRate(10001); // 100.01% (exceeds BPS_DENOMINATOR)
    }

    function test_PauseUnpause() public {
        vm.prank(owner);
        lending.pause();
        assertTrue(lending.paused());

        vm.prank(owner);
        lending.unpause();
        assertFalse(lending.paused());
    }

    function test_Pause_RevertIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        lending.pause();
    }

    // ============ View Function Tests ============
    function test_GetTotalCollateralValue() public {
        uint256 depositAmount1 = 1 * 1e18;
        uint256 depositAmount2 = 5000 * 1e6; // 5000 tokens with 6 decimals

        vm.startPrank(user1);
        collateralToken1.approve(address(lending), depositAmount1);
        lending.depositCollateral(address(collateralToken1), depositAmount1);

        collateralToken2.approve(address(lending), depositAmount2);
        lending.depositCollateral(address(collateralToken2), depositAmount2);
        vm.stopPrank();

        uint256 expectedValue1 = lending.getTokenPrice(address(collateralToken1));
        uint256 expectedValue2 = lending.getTokenPrice(address(collateralToken2));
        uint256 totalValue = lending.getTotalCollateralValue(user1);

        assertEq(totalValue, expectedValue1 + expectedValue2);
    }

    function test_GetCollateralTokens() public view {
        address[] memory tokens = lending.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(collateralToken1));
        assertEq(tokens[1], address(collateralToken2));
    }
}
