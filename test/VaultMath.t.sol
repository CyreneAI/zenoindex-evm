// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {VaultMath} from "../src/libraries/VaultMath.sol";
import {Constants} from "../src/libraries/Constants.sol";

contract VaultMathTest is Test {
    function test_ComputeFeeSplit_MatchesWorkedExample() public pure {
        VaultMath.FeeSplit memory s = VaultMath.computeFeeSplit(100_000_000, 100);
        assertEq(s.companyFee, 200_000);
        assertEq(s.managerFee, 800_000);
        assertEq(s.netAmount, 99_000_000);
    }

    function test_ComputeFeeSplit_ZeroFee() public pure {
        VaultMath.FeeSplit memory s = VaultMath.computeFeeSplit(100_000_000, 0);

        assertEq(s.companyFee, 0);
        assertEq(s.managerFee, 0);
        assertEq(s.netAmount, 100_000_000);
    }

    function test_ComputeFeeSplit_FullBps() public pure {
        VaultMath.FeeSplit memory s = VaultMath.computeFeeSplit(100_000_000, Constants.BPS_DENOM);

        uint256 feeAmount = 100_000_000;
        uint256 companyFee = (feeAmount * Constants.COMPANY_FEE_SHARE_BPS) / Constants.BPS_DENOM;

        assertEq(s.companyFee, companyFee);
        assertEq(s.managerFee, feeAmount - companyFee);
        assertEq(s.netAmount, 0);
    }

    function test_ComputeFeeSplit_RoundsDown() public pure {
        VaultMath.FeeSplit memory s = VaultMath.computeFeeSplit(1, 1);

        assertEq(s.companyFee, 0);
        assertEq(s.managerFee, 0);
        assertEq(s.netAmount, 1);
    }

    function testFuzz_ComputeFeeSplit_PreservesGrossAmount(uint256 grossAmount, uint16 feeBps) public pure {
        grossAmount = bound(grossAmount, 0, type(uint256).max / Constants.BPS_DENOM);

        feeBps = uint16(bound(feeBps, 0, Constants.BPS_DENOM));

        VaultMath.FeeSplit memory s = VaultMath.computeFeeSplit(grossAmount, feeBps);

        uint256 feeAmount = (grossAmount * uint256(feeBps)) / Constants.BPS_DENOM;

        assertEq(s.companyFee + s.managerFee, feeAmount);
        assertEq(s.netAmount + feeAmount, grossAmount);
    }

    function test_CalculateReverseGenesisShares_SeedTimesPriceScaleDivBaseline() public pure {
        uint256 baseline = 5_000_000_000;
        uint256 shares = VaultMath.calculateReverseGenesisShares(Constants.GENESIS_SEED_USDC, baseline);
        assertEq(shares, (Constants.GENESIS_SEED_USDC * Constants.PRICE_SCALE) / baseline);
    }

    function test_CalculateReverseGenesisShares_RevertsBelowMinBaseline() public {
        vm.expectRevert(VaultMath.InvalidBaselineSharePrice.selector);
        this.calculateReverseGenesisSharesExternal(Constants.GENESIS_SEED_USDC, Constants.MIN_BASELINE_SHARE_PRICE - 1);
    }

    function test_CalculateReverseGenesisShares_RevertsForZeroSeed() public {
        vm.expectRevert(VaultMath.ZeroAmount.selector);

        this.calculateReverseGenesisSharesExternal(0, Constants.MIN_BASELINE_SHARE_PRICE);
    }

    function test_CalculateReverseGenesisShares_AcceptsMinimumBaseline() public pure {
        uint256 shares =
            VaultMath.calculateReverseGenesisShares(Constants.GENESIS_SEED_USDC, Constants.MIN_BASELINE_SHARE_PRICE);

        assertEq(shares, (Constants.GENESIS_SEED_USDC * Constants.PRICE_SCALE) / Constants.MIN_BASELINE_SHARE_PRICE);
    }

    function test_CalculateReverseGenesisShares_AcceptsMaximumBaseline() public pure {
        uint256 shares =
            VaultMath.calculateReverseGenesisShares(Constants.GENESIS_SEED_USDC, Constants.MAX_BASELINE_SHARE_PRICE);

        assertEq(shares, (Constants.GENESIS_SEED_USDC * Constants.PRICE_SCALE) / Constants.MAX_BASELINE_SHARE_PRICE);
    }

    function test_CalculateReverseGenesisShares_RevertsAboveMaxBaseline() public {
        vm.expectRevert(VaultMath.InvalidBaselineSharePrice.selector);

        this.calculateReverseGenesisSharesExternal(Constants.GENESIS_SEED_USDC, Constants.MAX_BASELINE_SHARE_PRICE + 1);
    }

    function calculateReverseGenesisSharesExternal(uint256 seed, uint256 baseline) external pure returns (uint256) {
        return VaultMath.calculateReverseGenesisShares(seed, baseline);
    }

    function test_ComputeSharesToMint_NetTimesSharesDivNavPlusPending() public pure {
        uint256 s = VaultMath.computeSharesToMint(990_000_000, 200, 1_000_000_000, 0);
        assertEq(s, (990_000_000 * 200) / 1_000_000_000);
    }

    function test_ComputeSharesToMint_IncludesPendingUsdcInNav() public pure {
        uint256 s = VaultMath.computeSharesToMint(100, 200, 1_000, 100);

        uint256 expected = (uint256(100) * uint256(200)) / uint256(1_100);

        assertEq(s, expected);
    }

    function test_ComputeSharesToMint_RevertsWhenNavIsZero() public {
        vm.expectRevert(VaultMath.ZeroAmount.selector);

        this.computeSharesToMintExternal(100, 200, 0, 0);
    }

    function testFuzz_ComputeSharesToMint_IsBoundedByScaledDeposit(
        uint256 usdcDeposit,
        uint256 totalShares,
        uint256 totalNav,
        uint256 pendingUsdc
    ) public pure {
        totalShares = bound(totalShares, 1, type(uint256).max);

        totalNav = bound(totalNav, 0, type(uint256).max);
        pendingUsdc = bound(pendingUsdc, 0, type(uint256).max - totalNav);

        if (totalNav == 0 && pendingUsdc == 0) {
            pendingUsdc = 1;
        }

        uint256 nav = totalNav + pendingUsdc;

        usdcDeposit = bound(usdcDeposit, 0, type(uint256).max / totalShares);

        uint256 result = VaultMath.computeSharesToMint(usdcDeposit, totalShares, totalNav, pendingUsdc);

        assertLe(result * nav, usdcDeposit * totalShares);
    }

    function computeSharesToMintExternal(
        uint256 usdcDeposit,
        uint256 totalShares,
        uint256 totalNav,
        uint256 pendingUsdc
    ) external pure returns (uint256) {
        return VaultMath.computeSharesToMint(usdcDeposit, totalShares, totalNav, pendingUsdc);
    }

    function test_ComputeUsdcForShares_BasicCalculation() public pure {
        uint256 usdc = VaultMath.computeUsdcForShares(25, 100, 1_000);
        assertEq(usdc, 250);
    }

    function test_ComputeUsdcForShares_RevertsWhenTotalSharesZero() public {
        vm.expectRevert(VaultMath.ZeroAmount.selector);

        this.computeUsdcForSharesExternal(25, 0, 1_000);
    }

    function testFuzz_ComputeUsdcForShares_IsBoundedByNav(
        uint256 shares,
        uint256 totalShares,
        uint256 totalNavIncludingPending
    ) public pure {
        totalShares = bound(totalShares, 1, type(uint256).max);
        shares = bound(shares, 0, totalShares);

        if (shares == 0) {
            totalNavIncludingPending = bound(totalNavIncludingPending, 0, type(uint256).max);
        } else {
            totalNavIncludingPending = bound(totalNavIncludingPending, 0, type(uint256).max / shares);
        }

        uint256 result = VaultMath.computeUsdcForShares(shares, totalShares, totalNavIncludingPending);

        assertLe(result, totalNavIncludingPending);
    }

    function computeUsdcForSharesExternal(uint256 shares, uint256 totalShares, uint256 totalNavIncludingPending)
        external
        pure
        returns (uint256)
    {
        return VaultMath.computeUsdcForShares(shares, totalShares, totalNavIncludingPending);
    }

    function test_ComputeSharePrice_ReturnsPriceScaleWhenNoShares() public pure {
        assertEq(VaultMath.computeSharePrice(1_000, 0), Constants.PRICE_SCALE);
    }

    function test_ComputeSharePrice_CalculatesPriceWithShares() public pure {
        assertEq(VaultMath.computeSharePrice(1_000, 100), 10 * Constants.PRICE_SCALE);
    }

    function testFuzz_ComputeSharePrice_IsBoundedByScaledValue(uint256 usdcValue, uint256 totalShares) public pure {
        totalShares = bound(totalShares, 1, type(uint256).max);

        usdcValue = bound(usdcValue, 0, type(uint256).max / Constants.PRICE_SCALE);

        uint256 result = VaultMath.computeSharePrice(usdcValue, totalShares);

        assertLe(result * totalShares, usdcValue * Constants.PRICE_SCALE);
    }

    function test_ProRataAmount_BasicCalculation() public pure {
        assertEq(VaultMath.proRataAmount(1_000, 25, 100), 250);
    }

    function test_ProRataAmount_RevertsWhenTotalSharesZero() public {
        vm.expectRevert(VaultMath.ZeroAmount.selector);

        this.proRataAmountExternal(1_000, 25, 0);
    }

    function testFuzz_ProRataAmount_IsBoundedByBalance(uint256 balance, uint256 shares, uint256 totalShares)
        public
        pure
    {
        totalShares = bound(totalShares, 1, type(uint256).max);
        shares = bound(shares, 0, totalShares);
        balance = bound(balance, 0, type(uint256).max / totalShares);

        uint256 result = VaultMath.proRataAmount(balance, shares, totalShares);

        assertLe(result, balance);
    }

    function proRataAmountExternal(uint256 balance, uint256 shares, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return VaultMath.proRataAmount(balance, shares, totalShares);
    }

    function test_ComputeRedeemSwapAmounts_BasicCalculation() public pure {
        uint256[20] memory balances;

        balances[0] = 1_000;
        balances[1] = 2_000;

        uint256[20] memory amounts = VaultMath.computeRedeemSwapAmounts(balances, 2, 25, 100);

        assertEq(amounts[0], 250);
        assertEq(amounts[1], 500);
        assertEq(amounts[2], 0);
    }

    function test_ComputeRedeemSwapAmounts_AcceptsMaximumAssets() public pure {
        uint256[20] memory balances;

        for (uint8 i = 0; i < Constants.MAX_ASSETS; i++) {
            balances[i] = uint256(i + 1) * 100;
        }

        uint256[20] memory amounts = VaultMath.computeRedeemSwapAmounts(balances, uint8(Constants.MAX_ASSETS), 50, 100);

        for (uint8 i = 0; i < Constants.MAX_ASSETS; i++) {
            assertEq(amounts[i], balances[i] / 2);
        }
    }

    function test_ComputeRedeemSwapAmounts_RevertsWithNoAssets() public {
        uint256[20] memory balances;

        vm.expectRevert(VaultMath.NoAssets.selector);

        this.computeRedeemSwapAmountsExternal(balances, 0, 10, 100);
    }

    function test_ComputeRedeemSwapAmounts_RevertsWithTooManyAssets() public {
        uint256[20] memory balances;

        vm.expectRevert(VaultMath.TooManyAssets.selector);

        this.computeRedeemSwapAmountsExternal(balances, uint8(Constants.MAX_ASSETS + 1), 10, 100);
    }

    function test_ComputeRedeemSwapAmounts_RevertsWithZeroShares() public {
        uint256[20] memory balances;

        vm.expectRevert(VaultMath.ZeroAmount.selector);

        this.computeRedeemSwapAmountsExternal(balances, 1, 0, 100);
    }

    function test_ComputeRedeemSwapAmounts_RevertsWhenSharesExceedTotalShares() public {
        uint256[20] memory balances;

        vm.expectRevert(VaultMath.MathOverflow.selector);

        this.computeRedeemSwapAmountsExternal(balances, 1, 101, 100);
    }

    function computeRedeemSwapAmountsExternal(
        uint256[20] memory balances,
        uint8 numAssets,
        uint256 shares,
        uint256 totalShares
    ) external pure returns (uint256[20] memory) {
        return VaultMath.computeRedeemSwapAmounts(balances, numAssets, shares, totalShares);
    }

    function test_ComputePendingCarve_Proportional() public pure {
        uint256[20] memory targets;
        targets[0] = 30;
        targets[1] = 20;
        VaultMath.PendingCarve memory c = VaultMath.computePendingCarve(50, targets, 2, 10, 100);
        assertEq(c.usdcSlice, 5);
        assertEq(c.totalPendingUsdc, 45);
        assertEq(c.usdcTargetAmount[0], 27);
        assertEq(c.usdcTargetAmount[1], 18);
    }

    function test_ComputePendingCarve_AllowsZeroAssets() public pure {
        uint256[20] memory targets;

        VaultMath.PendingCarve memory c = VaultMath.computePendingCarve(100, targets, 0, 10, 100);

        assertEq(c.usdcSlice, 10);
        assertEq(c.totalPendingUsdc, 90);
    }

    function test_ComputePendingCarve_RevertsWithTooManyAssets() public {
        uint256[20] memory targets;

        vm.expectRevert(VaultMath.TooManyAssets.selector);

        this.computePendingCarveExternal(100, targets, uint8(Constants.MAX_ASSETS + 1), 10, 100);
    }

    function computePendingCarveExternal(
        uint256 totalPendingUsdc,
        uint256[20] memory usdcTargetAmount,
        uint8 numAssets,
        uint256 shares,
        uint256 totalShares
    ) external pure returns (VaultMath.PendingCarve memory) {
        return VaultMath.computePendingCarve(totalPendingUsdc, usdcTargetAmount, numAssets, shares, totalShares);
    }

    function test_ComputePendingCarve_RevertsWhenTotalSharesZero() public {
        uint256[20] memory targets;

        vm.expectRevert(VaultMath.ZeroAmount.selector);

        this.computePendingCarveExternal(100, targets, 2, 10, 0);
    }

    function test_ComputePendingCarve_RevertsWhenSharesExceedTotalShares() public {
        uint256[20] memory targets;

        vm.expectRevert(VaultMath.MathOverflow.selector);

        this.computePendingCarveExternal(100, targets, 2, 101, 100);
    }

    function test_ComputePendingCarve_ClampsTargetOverflow() public pure {
        uint256[20] memory targets;

        targets[0] = 80;
        targets[1] = 80;

        VaultMath.PendingCarve memory c = VaultMath.computePendingCarve(100, targets, 2, 50, 100);

        assertEq(c.usdcSlice, 50);
        assertEq(c.totalPendingUsdc, 50);
        assertEq(c.usdcTargetAmount[0], 40);
        assertEq(c.usdcTargetAmount[1], 10);
    }

    function test_ComputePendingCarve_ClearsSmallLastTargetDuringOverflow() public pure {
        uint256[20] memory targets;

        targets[0] = 200;
        targets[1] = 10;

        VaultMath.PendingCarve memory c = VaultMath.computePendingCarve(100, targets, 2, 50, 100);

        assertEq(c.usdcSlice, 50);
        assertEq(c.totalPendingUsdc, 50);
        assertEq(c.usdcTargetAmount[0], 50);
        assertEq(c.usdcTargetAmount[1], 0);
    }

    function test_AllocationSlice_BasicBps() public pure {
        assertEq(VaultMath.allocationSlice(100_000_000, 3000), 30_000_000);
    }

    function test_AllocationSlice_ZeroBps() public pure {
        assertEq(VaultMath.allocationSlice(100_000_000, 0), 0);
    }

    function testFuzz_AllocationSlice_IsBoundedByAmount(uint256 amount, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, Constants.BPS_DENOM));

        amount = bound(amount, 0, type(uint256).max / uint256(Constants.BPS_DENOM));

        uint256 result = VaultMath.allocationSlice(amount, bps);

        assertLe(result, amount);
    }

    function test_AllocationSlice_FullBps() public pure {
        assertEq(VaultMath.allocationSlice(100_000_000, Constants.BPS_DENOM), 100_000_000);
    }

    function test_AllocationSlice_RoundsDown() public pure {
        assertEq(VaultMath.allocationSlice(101, 3333), 33);
    }
}
