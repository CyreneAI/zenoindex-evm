// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Constants} from "./Constants.sol";

/// @notice Pure math for fee splits, genesis/share pricing, and redeem-carve accounting.
///         No SOL-leg math (assignSolTargetBps/legDeployAmount removed) — every asset is
///         a single USDC<->asset leg.
library VaultMath {
    error ZeroAmount();
    error MathOverflow();
    error InvalidBaselineSharePrice();
    error TooManyAssets();
    error NoAssets();

    struct FeeSplit {
        uint256 companyFee;
        uint256 managerFee;
        uint256 netAmount;
    }

    struct PendingCarve {
        uint256 usdcSlice;
        uint256 totalPendingUsdc;
        uint256[20] usdcTargetAmount;
    }

    /// @dev Mirrors `compute_fee_split` in fee_split.rs.
    function computeFeeSplit(uint256 grossAmount, uint16 feeBps) internal pure returns (FeeSplit memory s) {
        uint256 feeAmount = (grossAmount * uint256(feeBps)) / Constants.BPS_DENOM;
        uint256 companyFee = (feeAmount * Constants.COMPANY_FEE_SHARE_BPS) / Constants.BPS_DENOM;
        uint256 managerFee = feeAmount - companyFee;
        uint256 netAmount = grossAmount - feeAmount;
        s = FeeSplit({companyFee: companyFee, managerFee: managerFee, netAmount: netAmount});
    }

    /// @dev `shares = seed × PRICE_SCALE / baseline` — calculate_reverse_genesis_shares.
    function calculateReverseGenesisShares(uint256 seedUsdc, uint256 baselineSharePrice)
        internal
        pure
        returns (uint256)
    {
        if (seedUsdc == 0) revert ZeroAmount();
        if (
            baselineSharePrice < Constants.MIN_BASELINE_SHARE_PRICE
                || baselineSharePrice > Constants.MAX_BASELINE_SHARE_PRICE
        ) {
            revert InvalidBaselineSharePrice();
        }
        uint256 shares = (seedUsdc * Constants.PRICE_SCALE) / baselineSharePrice;
        if (shares == 0) revert ZeroAmount();
        return shares;
    }

    /// @dev `shares = usdc × total_shares / (nav + pending_usdc)`.
    function computeSharesToMint(uint256 usdcDeposit, uint256 totalShares, uint256 totalNav, uint256 pendingUsdc)
        internal
        pure
        returns (uint256)
    {
        uint256 nav = totalNav + pendingUsdc;
        if (nav == 0) revert ZeroAmount();
        return (usdcDeposit * totalShares) / nav;
    }

    /// @dev Inverse for Fixed-vault clamp: usdc = shares × total_nav / total_shares.
    function computeUsdcForShares(uint256 shares, uint256 totalShares, uint256 totalNavIncludingPending)
        internal
        pure
        returns (uint256)
    {
        if (totalShares == 0) revert ZeroAmount();
        return (shares * totalNavIncludingPending) / totalShares;
    }

    function computeSharePrice(uint256 usdcValue, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return Constants.PRICE_SCALE;
        return (usdcValue * Constants.PRICE_SCALE) / totalShares;
    }

    function proRataAmount(uint256 balance, uint256 shares, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) revert ZeroAmount();
        return (balance * shares) / totalShares;
    }

    /// @dev Mirrors compute_redeem_swap_amounts.
    function computeRedeemSwapAmounts(
        uint256[20] memory freeBalances,
        uint8 numAssets,
        uint256 shares,
        uint256 totalShares
    ) internal pure returns (uint256[20] memory amounts) {
        if (numAssets == 0) revert NoAssets();
        if (numAssets > Constants.MAX_ASSETS) revert TooManyAssets();
        if (shares == 0) revert ZeroAmount();
        if (totalShares < shares) revert MathOverflow();
        for (uint8 i = 0; i < numAssets; i++) {
            amounts[i] = proRataAmount(freeBalances[i], shares, totalShares);
        }
    }

    /// @dev Mirrors compute_pending_carve (SOL-leg fields removed — USDC-only pending).
    function computePendingCarve(
        uint256 totalPendingUsdc,
        uint256[20] memory usdcTargetAmount,
        uint8 numAssets,
        uint256 shares,
        uint256 totalShares
    ) internal pure returns (PendingCarve memory carve) {
        if (numAssets > Constants.MAX_ASSETS) revert TooManyAssets();
        if (totalShares == 0) revert ZeroAmount();
        if (totalShares < shares) revert MathOverflow();

        uint256 usdcSlice = proRataAmount(totalPendingUsdc, shares, totalShares);
        uint256 newPending = totalPendingUsdc - usdcSlice;

        uint256[20] memory newTargets = usdcTargetAmount;
        for (uint8 i = 0; i < numAssets; i++) {
            uint256 tSlice = proRataAmount(newTargets[i], shares, totalShares);
            newTargets[i] = newTargets[i] - tSlice;
        }

        uint256 targetsSum;
        for (uint8 i = 0; i < numAssets; i++) {
            targetsSum += newTargets[i];
        }
        if (targetsSum > newPending) {
            uint256 overflow = targetsSum - newPending;
            for (uint8 j = 0; j < numAssets; j++) {
                uint8 i = numAssets - 1 - j;
                if (overflow == 0) break;
                uint256 cut = newTargets[i] < overflow ? newTargets[i] : overflow;
                newTargets[i] -= cut;
                overflow -= cut;
            }
        }

        carve = PendingCarve({usdcSlice: usdcSlice, totalPendingUsdc: newPending, usdcTargetAmount: newTargets});
    }

    /// @dev Allocation slice: amount × bps / 10_000.
    function allocationSlice(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * uint256(bps)) / Constants.BPS_DENOM;
    }
}
