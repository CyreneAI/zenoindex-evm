# ZenoIndex EVM — mainnet review

**Date:** 2026-09-23
**Scope:** `src/` (`Vault`, `ZenoIndexVault`, `AccessMaster`, `UniswapV4Adapter`, `VaultMath`, `Constants`, tokens, interfaces)
**Toolchain:** Foundry 1.8.3, solc 0.8.26 (`via_ir`, cancun), OpenZeppelin 5.7.0
**This document** merges the pre-mainnet review, the bug-fix report, and the security audit.

---

## Verdict: go-ahead for mainnet

User-exploitable bugs that broke the contracts’ own invariants are fixed and covered by tests. What remains is either **ops** (every vault includes a USDC basket slot; keeper; post-deploy checklist) or **owner/deployer custody** (super-admin, manager, price table). Those are accepted as designed.

This is an internal go-ahead, not a third-party audit. Super-admin, adapter admin, vault manager, and the price keeper are trusted.

**Tests (local, this tree):** 168 passed, 0 failed.

| Suite | Passed |
|---|---|
| AccessMasterTest | 22 |
| AuditPoC | 68 |
| UniswapV4AdapterTest | 8 |
| VaultMathTest | 6 |
| ZenoIndexVaultTest | 64 |

PoCs: `forge test --match-test test_PoC -vv` (`test/AuditPoC.t.sol`).

---

## Coverage

`forge coverage --ir-minimum --report summary` (same 168 tests):

| File | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `src/AccessMaster.sol` | 97.56% (40/41) | 97.50% (39/40) | 100% (9/9) | 100% (11/11) |
| `src/Vault.sol` | 97.42% (416/427) | 89.95% (510/567) | 47.32% (53/112) | 95.65% (44/46) |
| `src/ZenoIndexVault.sol` | 90.80% (158/174) | 83.71% (185/221) | 42.86% (21/49) | 87.10% (27/31) |
| `src/adapters/UniswapV4Adapter.sol` | 90.77% (59/65) | 86.96% (80/92) | 33.33% (5/15) | 88.89% (8/9) |
| `src/libraries/VaultMath.sol` | 79.66% (47/59) | 64.44% (58/90) | 6.25% (1/16) | 88.89% (8/9) |
| `src/tokens/ERC20Minimal.sol` | 100% (32/32) | 100% (25/25) | 14.29% (1/7) | 100% (7/7) |
| `src/tokens/ShareToken.sol` | 100% (8/8) | 100% (4/4) | 0% (0/2) | 100% (4/4) |
| `src/mocks/MockERC20.sol` | 100% (3/3) | 100% (1/1) | — | 100% (2/2) |
| `src/mocks/MockSwapRouter.sol` | 0% (0/15) | 0% (0/20) | 0% (0/8) | 0% (0/2) |
| `script/Deploy.s.sol` | 0% (0/34) | 0% (0/43) | 0% (0/4) | 0% (0/2) |
| **Total** | **88.93% (763/858)** | **81.78% (902/1103)** | **40.54% (90/222)** | **90.24% (111/123)** |

Deploy script and `MockSwapRouter` are unused by the suite (vault tests go through a real V4 `PoolManager`). Branch coverage is thin on `VaultMath` (6%) and the adapter (33%) — error paths more than happy paths.

---

## Bugs fixed

Severity: **High** = users lose value or anyone can freeze a vault. **Medium** = needs a token/key/config, or recoverable liveness. **Low** = views or admin-only checks.

| ID | Issue | Severity | Test |
|---|---|---|---|
| B-1 | Dust `requestRedeem` left `activeRedeemCount > 0` forever; write-off and retire blocked | High | `test_RequestRedeem_RevertsWhenEverythingRoundsToZero` |
| B-2 | USDC basket slot counted pending + escrow as free, then paid the carve again | High | `test_RequestRedeem_UsdcSlotExcludesPendingAndEscrow` |
| B-3 | `UniswapV4Adapter.swap` pulled from any `from` that had approved it | Medium | `test_swap_revertsForUnauthorizedCaller_evenWithVictimAllowance`, `test_ExecuteSwap_RevertsForNonClone` |
| B-4 | `ADMIN_ROLE` and `_superAdmin` could diverge via OZ `grantRole` | Medium | `test_AdminRole_CannotBeGrantedRevokedOrRenouncedDirectly`, `test_AcceptSuperAdmin_*` |
| B-5 | Wind-down left AMM dust; donated 1 wei pinned slots (`SlotFull`) | Medium | `test_ExecuteRebalance_WindDownSellsDownToSubDriftBandDust`, `test_ExecuteRebalance_DonatedDustDoesNotBlockRetire` |
| B-6 | `require(token.transfer)` broke USDT-class tokens | Medium | (SafeERC20 throughout Vault + adapter) |
| B-7 | `previewDeposit` ignored share cap; clamp over-earmarked pending | Low | `test_PreviewDeposit_MatchesClampedDeposit` |
| B-8 | `setFeeRecipient(address(0))` accepted | Low | `test_SetFeeRecipient_RevertsOnZero` |

**B-1.** Reject a redeem whose USDC credit and every swap leg round to 0. `claim` closes a zero escrow. `claimInKind` / `forceSettleRedeem` (7 days) can still clear an abandoned redeem.

**B-2.** `_freeBalance` on a USDC slot excludes `totalPendingUsdc + vaultRedeemEscrowTotal`. That slot’s share goes straight to escrow (no USDC→USDC swap).

**B-3.** Adapter: `setAuthorizedCaller`. Factory `executeSwap`: registered clones only, `from == msg.sender`.

**B-4.** Two-step `setSuperAdmin` / `acceptSuperAdmin`. Inherited `grantRole` / `revokeRole` / `renounceRole` revert for `ADMIN_ROLE`.

**B-5.** 0%-target slot sells its whole free balance and retires at `RETIRE_DUST_USDC` ($0.001).

**B-6.** OpenZeppelin `SafeERC20` (`safeTransfer`, `safeTransferFrom`, `forceApprove`). Swap output is the vault’s balance delta.

**B-7.** Shared `_quoteDeposit` for deposit and preview. Pending recorded from `fee.netAmount`.

---

## Design changes (also shipped)

| Change | Test |
|---|---|
| `createVault` is super-admin or `setVaultCreator`; requires router + a price on every non-USDC asset | `test_CreateVault_RevertsForNonAllowlistedCaller`, `…WhenNoRouterSet`, `…WhenAssetHasNoPrice` |
| Price table: reject zero; `StalePrice` after 1 day; one update ≤ 20% | `test_SetPrice_RejectsZeroAndOversizedMove`, `test_StalePrice_BlocksDepositUntilRefreshed` |
| Operators scoped per vault; swap floor = table − 3% | `test_Operators_AreScopedPerVault`, `test_Swap_PriceTableFloorOverridesZeroMinOut` |
| `setUsdcToken` reverts once `totalVaults > 0` | `test_SetUsdcToken_RevertsOnceAVaultExists` |
| Emergency/pause halt create, genesis, deposits, swaps, rebalance. `setPrice` stays open. In-kind exit stays open | `test_Emergency_HaltsDepositsAndSwapsButNotInKindExit`, `test_Pause_HaltsManagerSwapsAndRebalance` |
| `claimInKind`; `forceSettleRedeem` after 7 days | `test_ClaimInKind_SettlesUnswappedLegsInAsset`, `test_ForceSettleRedeem_OnlyAfterTimeout` |
| `sweepWrittenOff`; USDC cannot be written off | `test_WriteOff_LeavesTokensInCustodyUntilSwept` |
| V4 hooks allowlisted (`setHookAllowed`) | `test_setPool_rejectsHookUntilAllowlisted` |
| `solc` pinned 0.8.26 / cancun | — |

Fee-on-transfer / rebasing: swaps revert instead of mis-counting. `createAsset` documents them as unsupported. Listing is off-chain.

---

## Remaining findings — how we ship

### Operate (no extra code)

**H-1 / O-1 — Spare USDC missing from NAV without a USDC slot (High).**  
`sumNav` only values USDC when USDC is a basket slot. A rebalance *sale* (or retired pending) then sits uncounted. PoC `test_PoC_RebalanceSaleUnderstatesNav`: NAV dropped from ~99,940 to ~49,980 USDC while ~49,942 USDC sat in the vault. Anyone depositing in that window mints cheap shares.

**Ship rule:** every production vault includes a **USDC slot** in `assetIds` / `allocationBps`. With that slot, `sumNav` already counts the cash. Do not ship a 100% non-stable basket.

**M-1 — Unpriced asset on retarget (Medium).**  
`createVault` requires a price; `setTargetAllocations` does not. A 1-wei donation of an unpriced mint reverts every NAV read (`test_PoC_UnpricedAssetDonationBricksDeposits`).

**Ship rule:** only retarget to assets that already have `setPrice` / `setPriceWhole`. Same screen as `createVault`.

Also: post-deploy checklist (below), daily price keeper, no fee-on-transfer or rebasing mints.

### Owner / deployer — accepted as designed

A leaked or malicious admin key can still move funds. That is custody.

| ID | What it is | Live with it by |
|---|---|---|
| **H-2** | Super-admin can `setVaultOperator` on itself, propose write-off, confirm, and `sweepWrittenOff` to any `to`. PoC: `test_PoC_SuperAdminUnilateralDrain` | Super-admin is a **multisig**. Do not make that multisig a per-vault operator unless you intend the sweep path |
| **H-3** | Deposits use the admin table (up to 1 day stale); redeems pay real balances / in-kind | Keeper cadence; optional deposit fee |
| **M-4** | `maxPriceChangeBps` can be walked with repeated `setPrice`, or set to 0 | Do not zero the bound on mainnet |
| **M-5** | Manager can rebalance / churn inside the 3% swap floor | Trust the manager; tighten slippage if you want less room |
| **L-5, L-6** | Adapter admin is one-step; no `setVaultManager` | Same multisig as adapter admin; `setVaultOperator` if a manager key is lost |

### Non-blocking (liveness / UX)

- **M-2** — An open redeem blocks write-off and slot retire. `forceSettleRedeem` after 7 days. Wait or settle; a busy vault may rarely hit zero open redeems. PoC: `test_PoC_OpenRedeemBlocksWriteOff`.
- **M-3** — In-kind settle is all-or-nothing. A reverting / allowlisted token traps that user’s redeem. Prefer liquid ERC-20s.
- **L-1** — One stale price reverts the whole vault’s NAV. Keeper monitoring.
- **L-2 … L-4, L-7** — proposal expiry, global `setAssetActive`, USDC-slot rebalance path, share decimals.
- **I-1 … I-6** — mixed revert style, unindexed events, `ERC20Minimal` burn-to-zero, stale Solana comments.

---

## Checked and found sound

- Reentrancy: OZ 5.7 namespaced guard; storage `0` is not-entered, so ERC-1167 clones work. Value-moving Vault entry points are `nonReentrant`.
- Init: implementation `_disableInitializers()`; clone + `init` in one tx.
- Swaps: clone-only `executeSwap`, authorized adapter, `unlockCallback` only from `PoolManager`, approve exact then zero, output by balance delta.
- Redeem bookkeeping: reserved / escrow / pending stay consistent; USDC-slot double-count fixed.
- `AccessMaster`: role and `superAdmin()` cannot drift; two-step transfer.
- Share-cap clamp: `_quoteDeposit` matches `previewDeposit`.

---

## Deploy runbook

1. Deploy `Vault` impl, `AccessMaster` (**multisig** as super-admin + treasury), `ZenoIndexVault`, `UniswapV4Adapter`.
2. Adapter: `setAuthorizedCaller(factory, true)`; register pools; hooks `address(0)`.
3. Factory: `setSwapRouter`; `setPriceWhole` for every mint; `setVaultCreator`.
4. Create vaults **with a USDC slot**.
5. Genesis, then start the price keeper (at least daily, or deposits halt with `StalePrice`).
6. Confirm a random EOA `createVault` reverts `NotVaultCreator`.
7. Confirm a random EOA `adapter.swap` reverts `NotAuthorizedCaller`.

If `Deploy.s.sol` used a hot EOA as super-admin, two-step `setSuperAdmin` / `acceptSuperAdmin` onto the multisig **before the first user deposit**.

---

## Limitations

Manual review plus the 168-test suite. No fuzzing or formal verification. `lib/`, keepers, and live V4 pool config are out of scope. Branch coverage on `VaultMath` and adapter error paths is low. Re-run:

```bash
forge test --summary
forge coverage --ir-minimum --report summary
```
