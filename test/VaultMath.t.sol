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

    function test_CalculateReverseGenesisShares_SeedTimesPriceScaleDivBaseline() public pure {
        uint256 baseline = 5_000_000_000;
        uint256 shares = VaultMath.calculateReverseGenesisShares(Constants.GENESIS_SEED_USDC, baseline);
        assertEq(shares, (Constants.GENESIS_SEED_USDC * Constants.PRICE_SCALE) / baseline);
    }

    function test_CalculateReverseGenesisShares_RevertsBelowMinBaseline() public {
        vm.expectRevert(VaultMath.InvalidBaselineSharePrice.selector);
        this.calculateReverseGenesisSharesExternal(
            Constants.GENESIS_SEED_USDC, Constants.MIN_BASELINE_SHARE_PRICE - 1
        );
    }

    function calculateReverseGenesisSharesExternal(uint256 seed, uint256 baseline) external pure returns (uint256) {
        return VaultMath.calculateReverseGenesisShares(seed, baseline);
    }

    function test_ComputeSharesToMint_NetTimesSharesDivNavPlusPending() public pure {
        uint256 s = VaultMath.computeSharesToMint(990_000_000, 200, 1_000_000_000, 0);
        assertEq(s, (990_000_000 * 200) / 1_000_000_000);
    }

    function test_ComputePendingCarve_ProportionalNoSolField() public pure {
        uint256[20] memory targets;
        targets[0] = 30;
        targets[1] = 20;
        VaultMath.PendingCarve memory c = VaultMath.computePendingCarve(50, targets, 2, 10, 100);
        assertEq(c.usdcSlice, 5);
        assertEq(c.totalPendingUsdc, 45);
        assertEq(c.usdcTargetAmount[0], 27);
        assertEq(c.usdcTargetAmount[1], 18);
    }

    function test_AllocationSlice_BasicBps() public pure {
        assertEq(VaultMath.allocationSlice(100_000_000, 3000), 30_000_000);
    }
}
