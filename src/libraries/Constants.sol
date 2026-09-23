// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Protocol-wide constants for zeno_index_vault's clone-factory architecture.
///         No wrapped-native/SOL leg concept — every asset is a single USDC<->asset leg.
library Constants {
    /// @dev Vault asset-slot cap. Raised from the Solana program's 8 since NAV/redeem gas
    ///      scales linearly with slot count and 20 stays comfortably under block gas limits.
    uint256 internal constant MAX_ASSETS = 20;

    /// Fixed-point scale for share price: 1e9 (9-decimal).
    uint256 internal constant PRICE_SCALE = 1_000_000_000;

    /// 1 USDC in 6-decimal base units — hardcoded genesis seed.
    uint256 internal constant GENESIS_SEED_USDC = 1_000_000;

    /// Minimum baseline share price (PRICE_SCALE units) = $0.00001.
    uint256 internal constant MIN_BASELINE_SHARE_PRICE = 10_000;

    /// Maximum baseline share price (PRICE_SCALE units) = $100_000.
    uint256 internal constant MAX_BASELINE_SHARE_PRICE = 100_000 * PRICE_SCALE;

    uint16 internal constant MAX_DEPOSIT_FEE_BPS = 600; // 6%
    uint16 internal constant MIN_REDEEM_FEE_BPS = 50; // 0.5%
    uint16 internal constant MAX_REDEEM_FEE_BPS = 1000; // 10%

    /// Company's fixed cut of the fee amount itself (not of gross). 20%.
    uint256 internal constant COMPANY_FEE_SHARE_BPS = 2_000;

    uint16 internal constant BPS_DENOM = 10_000;

    /// @dev Path A rebalance drift-band: an asset within 0.5% (absolute) of its target
    ///      weight is skipped by executeRebalance, so ordinary price drift doesn't churn.
    uint16 internal constant REBALANCE_DRIFT_BPS = 50;

    /// @dev A 0%-target slot retires once its free balance is worth at most this (USDC 6-dec,
    ///      $0.001). Anything left behind stays in the vault untracked; the bar is kept tiny
    ///      so real value is always sold first, while donated dust can't pin the slot open.
    uint256 internal constant RETIRE_DUST_USDC = 1_000;

    /// @dev After this long, anyone may settle an open redeem in-kind (Vault.forceSettleRedeem).
    uint256 internal constant REDEEM_TIMEOUT = 7 days;
}
