# ZenoIndex EVM — mainnet review

**Date:** 2026-09-30
**Scope:** `src/` (`Vault`, `ZenoIndexVault`, `AccessMaster`, `UniswapV4Adapter`, `VaultMath`, `Constants`, tokens, interfaces)
**Toolchain:** Foundry 1.8.3, solc 0.8.26 (`via_ir`, cancun), OpenZeppelin 5.7.0
**This document** merges the pre-mainnet review, the bug-fix report, and the security audit.

---

## Verdict: go-ahead for mainnet

User-exploitable bugs that broke the contracts’ own invariants are fixed and covered by tests. What remains is either **ops** (production vault configuration; keeper; post-deploy checklist) or **owner/deployer custody** (super-admin, manager, price table). Those are accepted as designed.

This is an internal go-ahead, not a third-party audit. Super-admin, adapter admin, vault manager, and the price keeper are trusted.

**Tests (local, this tree):** 221 passed, 0 failed, 0 skipped.

| Suite | Passed |
|---|---:|
| AccessMasterTest | 22 |
| AuditPoC | 75 |
| UniswapV4AdapterTest | 11 |
| VaultMathTest | 42 |
| ZenoIndexVaultTest | 71 |
| **Total** | **221** |

PoCs: `forge test --match-test test_PoC -vv` (`test/AuditPoC.t.sol`).

---

## Coverage

`forge coverage --ir-minimum --report summary` (current 221-test suite):

| File | Lines | Statements | Branches | Funcs |
|---|---:|---:|---:|---:|
| `src/AccessMaster.sol` | 97.56% | 97.50% | 100.00% | 100.00% |
| `src/Vault.sol` | 97.44% | 90.22% | 51.33% | 95.65% |
| `src/ZenoIndexVault.sol` | 91.21% | 84.55% | 44.00% | 87.50% |
| `src/adapters/UniswapV4Adapter.sol` | 90.77% | 86.96% | 53.33% | 88.89% |
| `src/libraries/VaultMath.sol` | 96.61% | 96.67% | 93.75% | 100.00% |
| `src/tokens/ERC20Minimal.sol` | 100.00% | 100.00% | 14.29% | 100.00% |
| `src/tokens/ShareToken.sol` | 100.00% | 100.00% | 0.00% | 100.00% |
| `src/mocks/MockERC20.sol` | 100.00% | 100.00% | — | 100.00% |
| `src/mocks/MockSwapRouter.sol` | 0.00% | 0.00% | 0.00% | 0.00% |
| `script/Deploy.s.sol` | 0.00% | 0.00% | 0.00% | 0.00% |
| **Total** | **90.22%** | **85.23%** | **50.45%** | **91.13%** |

Deploy script and `MockSwapRouter` are unused by the suite (vault tests go through a real V4 `PoolManager`). The current suite materially expands coverage of financial math and defensive error paths. `VaultMath` now has 93.75% branch coverage with deterministic and fuzz tests, while `AccessMaster` has 100% branch coverage. Adapter branch coverage is 53.33% after adding constructor, pool configuration, and callback authorization regressions.

Remaining uncovered branches are primarily defensive or internally inconsistent states rather than demonstrated user-exploitable bugs. No additional tests were added solely to maximize the coverage percentage.

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

### Phase 1 hardening fixes

| ID | Issue | Severity | Regression coverage |
|---|---|---|---|
| H-1 / O-1 | Unregistered/spare USDC could be omitted from NAV after rebalance sale proceeds | High | `test_ExecuteRebalance_SaleProceedsRemainInNav`, `test_RebalanceSaleDoesNotUnderstateNav` |
| M-1 | Target allocations could previously include an unpriced asset | Medium | `test_SetTargetAllocations_RevertsWhenAssetHasNoPrice` |

**H-1 / O-1.** `sumNav` now accounts for free USDC held by the vault even when USDC is not registered as an asset slot. Rebalance sale proceeds therefore remain included in NAV.

**M-1.** `setTargetAllocations` now requires every non-USDC target asset to have a configured price through `hasPrice()`.
---
### Phase 2 hardening

- **UniswapV4Adapter:** added defensive regression tests covering zero-address constructor inputs, zero-token pool configuration, and unauthorized `unlockCallback` callers.
- **Vault reactivation:** strengthened reactivation coverage to verify that written-off balances remain in custody, the written-off state is cleared, the balance is restored, and the asset returns as a 0%-target slot.
- **AccessMaster:** reviewed two-step super-admin transfer semantics and verified that `ADMIN_ROLE` cannot be directly granted, revoked, or renounced.
- **ShareToken:** reviewed the 6-decimal share-token configuration against the internal `PRICE_SCALE`; no production change was required.

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

**Ship rule:** every production vault includes a **USDC slot** in `assetIds` / `allocationBps` as the production deployment convention. This keeps the basket explicit about its stablecoin leg.

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

Manual review plus the current 221-test suite. The suite includes targeted fuzz tests for VaultMath financial invariants. No formal verification was performed. `lib/`, keepers, and live V4 pool configuration remain out of scope.

Branch coverage remains intentionally incomplete for several defensive or internally inconsistent states. Coverage was not treated as a substitute for security analysis.

Re-run:

```bash
forge test --summary
forge coverage --ir-minimum --report summary
```
