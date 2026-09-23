# Pre-mainnet review — resolution

**Review date:** 2026-09-23
**Status:** All 13 issues and the "Also fix" list are addressed in code and covered by regression tests (`forge test`: 100 passing). One item (fee-on-transfer / rebasing) is only partly solvable on-chain; see below. One new issue found while fixing is still **open**; see [Still open](#still-open).

Legend: **Bug** = the code broke its own invariants. **Design** = the code worked as written; the policy or trust model changed.

---

## 1. `createVault` is permissionless: fixed (Design)

`createVault` now requires super-admin or an account allowlisted with `ZenoIndexVault.setVaultCreator`. Every entry in `vaultClones` is official, and clones are tracked in `isVaultClone`.
Tests: `test_CreateVault_RevertsForNonAllowlistedCaller`

## 2. NAV is an unbounded admin price table: fixed (Design)

- A zero price is rejected (`ZeroPrice`).
- Freshness: every quote reverts `StalePrice` once a price is older than `maxPriceAge` (default 1 day, 0 disables).
- Bounds: one update can't move a price by more than `maxPriceChangeBps` (default 20%, 0 disables).

This is still an admin-pushed table, not a TWAP. A keeper must refresh prices daily or deposits and rebalances halt.
Tests: `test_SetPrice_RejectsZeroAndOversizedMove`, `test_StalePrice_BlocksDepositUntilRefreshed`

## 3. Zero-output redeem freezes write-off and slot retire: fixed (Bug)

`requestRedeem` reverts `ZeroAmount` when the USDC credit and every swap leg round to 0. `claim` no longer reverts on a zero escrow; it just closes the redeem.
Tests: `test_RequestRedeem_RevertsWhenEverythingRoundsToZero`

## 4. Super-admin transfer is one-step and can split-brain: fixed (Bug for the split, Design for two-step)

- Two-step transfer: `setSuperAdmin` proposes `pendingSuperAdmin`, then `acceptSuperAdmin` completes it. A wrong address is fixed by proposing again.
- `grantRole` / `revokeRole` / `renounceRole` revert for `ADMIN_ROLE`, so the role holder and `superAdmin()` stay in lockstep.

Tests: `AccessMaster.t.sol`: `test_SetSuperAdmin_OnlyProposesUntilAccepted`, `test_AcceptSuperAdmin_*`, `test_SetSuperAdmin_TypoIsRecoverableByReproposing`, `test_AdminRole_CannotBeGrantedRevokedOrRenouncedDirectly`

## 5. Global operator has custody of every vault: fixed (Design)

- Vault manager powers come from `vaultManager` or an operator scoped to **that vault** (`ZenoIndexVault.setVaultOperator(vaultId, account, allowed)`). A global `AccessMaster` operator now only manages the asset registry.
- Price-table swap floor: `executeSwap` raises every `minAmountOut` to `swapFloor`, which is the price-table quote less `maxSwapSlippageBps` (default 3%). `minOut = 0` no longer means "any price".

Tests: `test_Operators_AreScopedPerVault`, `test_Swap_PriceTableFloorOverridesZeroMinOut`

## 6. `setUsdcToken` after live vaults desyncs accounting: fixed (Design)

`setUsdcToken` reverts `VaultsExist` once `totalVaults > 0`.
Tests: `test_SetUsdcToken_RevertsOnceAVaultExists`

## 7. Emergency / pause do not halt swaps, rebalance, or `setPrice`: fixed (Design)

| Flag | Now blocks | Still open |
|---|---|---|
| `isEmergency` | `createVault`, genesis, deposits, **every swap** (enforced in `executeSwap`), rebalance | `requestRedeem`, `claim`, `claimInKind`, `setPrice` |
| `paused` / `adminLocked` | genesis, deposits, `swapUsdcToAsset`, `executeRebalance` | user exits (`swapAssetToUsdc` is blocked by `adminLocked` only) |

**Deliberate change from the review:** `setPrice` stays callable during an emergency, so a bad price can be corrected while every value-moving path is frozen. Blocking it would force an unfreeze before the fix.
Tests: `test_Emergency_HaltsDepositsAndSwapsButNotInKindExit`, `test_Pause_HaltsManagerSwapsAndRebalance`

## 8. Redeem cannot be cancelled: fixed (Design)

- `claimInKind()`: the redeemer closes the redeem at any time (even during pause or emergency). Unswapped legs are paid in the asset itself, with the redeem fee taken in-kind, plus any escrowed USDC.
- `forceSettleRedeem(user)`: after `Constants.REDEEM_TIMEOUT` (7 days) anyone can settle an abandoned redeem in-kind. Proceeds go to the redeemer. An abandoned or griefing redeem can therefore no longer block write-off or slot retire forever.

Tests: `test_ClaimInKind_SettlesUnswappedLegsInAsset`, `test_ForceSettleRedeem_OnlyAfterTimeout`

## 9. `previewDeposit` disagrees with the share-cap clamp: fixed (Bug)

`deposit` and `previewDeposit` share `_quoteDeposit`, including the clamp. On the clamp path the fee is recomputed from the clamped gross, and pending is earmarked from `fee.netAmount` (the net cash actually kept).
Tests: `test_PreviewDeposit_MatchesClampedDeposit`

## 10. Wind-down dust never retires the slot: fixed (Bug)

A 0%-target slot now sells its **whole** free balance (not a price-sized delta). It retires in the same call once what's left is worth at most `Constants.RETIRE_DUST_USDC` ($0.001), so donated dust can't pin a slot open.
Tests: `test_ExecuteRebalance_WindDownSellsDownToSubDriftBandDust`, `test_ExecuteRebalance_DonatedDustDoesNotBlockRetire`

## 11. Written-off tokens have no sweep: fixed (Design)

`ZenoIndexVault.sweepWrittenOff(vaultId, assetId, to)` (super-admin) moves a written-off asset's balance out through `Vault.executeSweep`. USDC can't be written off (that would strand pending and escrowed cash). The write-off's NAV snapshot is best-effort, so a dead token's stale price can't block it.
Tests: `test_WriteOff_LeavesTokensInCustodyUntilSwept`, `test_SweepWrittenOff_RevertsForLiveAssetAndNonSuperAdmin`

## 12. V4 adapter allows arbitrary hooks: fixed (Design)

`setPool` requires `hooks == address(0)` or a hook allowlisted with `setHookAllowed`.
Tests: `test_setPool_rejectsHookUntilAllowlisted`

## 13. `executeSwap` is public: fixed (Bug)

- `ZenoIndexVault.executeSwap`: registered clones only, and `from == msg.sender`.
- The actual hole was **`UniswapV4Adapter.swap`**: it was public and pulled from any `from`. It now requires an admin-authorized caller (`setAuthorizedCaller`). Authorize the factory after deploy.

Tests: `test_ExecuteSwap_RevertsForNonClone`, `test_swap_revertsForUnauthorizedCaller_evenWithVictimAllowance`

---

## Also fix

- **SafeERC20: fixed (Bug).** `Vault` and `UniswapV4Adapter` use `safeTransfer` / `safeTransferFrom` / `forceApprove`.
- **`setFeeRecipient(address(0))`: fixed (Bug).** Reverts `ZeroAddress`. Test: `test_SetFeeRecipient_RevertsOnZero`.
- **Fee-on-transfer / rebasing: partly fixed (Design).** Swap outputs are measured by balance delta, and a fee-on-transfer input makes the adapter's payment revert, so these tokens fail loudly instead of mis-accounting. Contracts can't reliably detect such tokens (fees can be switched on later), so `createAsset` documents them as unsupported. **Asset listing must screen for them off-chain.**
- **Deploy: fixed.** `createVault` reverts until the router is set and every non-USDC basket asset has a price (tests: `test_CreateVault_RevertsWhenNoRouterSet`, `test_CreateVault_RevertsWhenAssetHasNoPrice`). `Deploy.s.sol` can price assets at deploy (`ASSET_i_PRICE`) and lists the post-deploy steps.
- **Pin `solc`: fixed.** `foundry.toml` pins `solc_version = "0.8.26"`, `evm_version = "cancun"`.

## New issue found while fixing

- **USDC as a basket slot double-counted in redeems: fixed (Bug).** `requestRedeem` counted pending and escrowed USDC as the USDC slot's free balance, then paid the pending share again through the carve. It now excludes both, and credits the USDC slot's share straight to escrow (no swap leg).
  Test: `test_RequestRedeem_UsdcSlotExcludesPendingAndEscrow`

---

## Still open

1. **Spare USDC is not in NAV unless the vault has a USDC slot.** `totalNav = sumNav(slots) + totalPendingUsdc`. USDC from rebalance sales, or pending dropped when a slot retires or is written off, sits in the vault but is counted nowhere. Between an overweight sale and the matching buy, NAV is understated, so a deposit in that window mints cheap shares. **Fix:** count the vault's USDC balance minus `totalPendingUsdc + vaultRedeemEscrowTotal` in NAV even without a USDC slot.
2. **`script/check-readme-src-docs.sh` fails** on `NavCalculation.sol` / `SwapExecutor.sol` sections. It was already failing before these fixes because those contracts were merged into `ZenoIndexVault.sol`; the script needs updating.
