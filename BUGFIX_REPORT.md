# Bug-fix report: response to PRE_MAINNET_REVIEW.md

**Date:** 2026-09-21
**Scope:** `src/Vault.sol`, `src/ZenoIndexVault.sol`, `test/ZenoIndexVault.t.sol`
**Source:** [`PRE_MAINNET_REVIEW.md`](./PRE_MAINNET_REVIEW.md)
**Toolchain:** Foundry 1.8.3, solc 0.8.26

This pass fixes all 6 Critical findings and 4 High findings selected as
mechanical/localized (reentrancy, allowance hygiene, creation gate, oracle
zero-address/rotation). The remaining High findings and the testing gaps are
**not** in scope here — see "Not fixed" below.

35 pre-existing tests still pass unmodified in behavior (some assertions were
loosened earlier for real-AMM slippage, unrelated to this pass). 14 new
regression tests were added, one per fix, each verified to fail when its fix
is reverted. **49/49 tests pass.**

---

## Critical — fixed

### 1. Anyone can spend pending USDC down an arbitrary swap path

**Fix (`src/Vault.sol`, `swapUsdcToAsset`):**
- Added `require(path[path.length - 1] == mint)` (via `PathEnd` error) so the
  swap can no longer land on an unintended token.
- Restricted the function to `onlyManager` (manager or a registered
  operator), closing the permissionless-caller / free sandwich surface
  entirely rather than relying on `minAssetOut` alone.

Regression tests: `test_SwapUsdcToAsset_RevertsWhenPathEndsOnWrongMint`,
`test_SwapUsdcToAsset_RevertsForNonManager`.

### 2. Rebalance buys spend redeem escrow and pending USDC

**Fix (`src/Vault.sol`, `executeRebalance`, underweight branch):**
```solidity
uint256 usdcBal = ERC20Minimal(usdc).balanceOf(address(this));
uint256 earmarked = totalPendingUsdc + vaultRedeemEscrowTotal;
uint256 usdcFree = usdcBal > earmarked ? usdcBal - earmarked : 0;
uint256 buyAmount = deltaValueUsdc < usdcFree ? deltaValueUsdc : usdcFree;
```
`usdcFree` now excludes both counters instead of reading raw balance. Also
added `path[last] == mint` (buy) and `path[last] == usdc` (sell) checks —
previously only `path[0]` was validated on either leg.

Regression test: `test_ExecuteRebalance_UnderweightBuyNeverSpendsEscrowedOrPendingUsdc`
(asserts `totalPendingUsdc` and `vaultRedeemEscrowTotal` are byte-for-byte
unchanged by a buy, and that vault USDC balance stays ≥ the sum of both after
the trade). `test_ExecuteRebalance_RevertsWhenPathEndsOnWrongToken` covers
the path-end check on the sell leg.

### 3. Deploy script is the mock stack, including the mainnet comment

**Status: already fixed at `HEAD` (commit `4c32107`), but the working tree
had regressed to the mock stack in an uncommitted edit.** `script/Deploy.s.sol`
and `.env.example` were restored to the committed version via
`git checkout HEAD -- script/Deploy.s.sol .env.example`. The committed script
takes `STABLECOIN`, `PRICE_ORACLE`, and `SWAP_ROUTER` as required env vars
(`vm.envAddress`, no default, `require(... != address(0))`) and imports no
`Mock*` contracts.

Gap noted, not fixed: `.env.example` documents `PRICE_ORACLE`/`SWAP_ROUTER` as
commented-out examples further down the file but the "Required" block only
calls out `STABLECOIN` — worth tightening in a docs-only follow-up so an
operator can't miss them; the script itself will still hard-revert if unset,
so this is not a fund-safety issue.

### 4. Fee caps in `Constants` are never applied

**Fix (`src/Vault.sol`, `init`):**
```solidity
if (depositFeeBps_ > Constants.MAX_DEPOSIT_FEE_BPS) revert FeeOutOfBounds();
if (redeemFeeBps_ < Constants.MIN_REDEEM_FEE_BPS || redeemFeeBps_ > Constants.MAX_REDEEM_FEE_BPS) {
    revert FeeOutOfBounds();
}
```
**Fix (`src/ZenoIndexVault.sol`, `createVault`):** the creation gate is now
mandatory — `etfCreationAuthority == address(0)` reverts with
`CreationGateNotSet()` instead of silently allowing any caller through.
Super-admin can still always create vaults regardless of the gate (unchanged),
so the admin can bootstrap by setting the gate to itself first.

Regression tests: `test_CreateVault_RevertsWhenDepositFeeExceedsMax`,
`test_CreateVault_RevertsWhenRedeemFeeBelowMin`,
`test_CreateVault_RevertsWhenCreationGateUnset`.

### 5. Duplicate asset IDs double-count NAV

**Fix:**
- `Vault.init` and `Vault.setTargetAllocations` now reject a duplicate
  `assetId` within the same input array (`DuplicateAsset` error), via an
  O(n²) pairwise scan — `n` is capped at `Constants.MAX_ASSETS = 20`, so this
  is cheap.
- `ZenoIndexVault.createAsset` now tracks registered mints
  (`_mintRegistered` mapping) and rejects a duplicate `mint` with
  `DuplicateMint()`.
- `ZenoIndexVault.createVault` also rejects duplicate `assetIds` in the
  vault-creation params directly (`AlreadyExists`), independent of `Vault.init`'s
  own check, so the factory fails fast before cloning.

Regression tests: `test_CreateVault_RevertsOnDuplicateAssetIds`,
`test_SetTargetAllocations_RevertsOnDuplicateAssetIds`,
`test_CreateAsset_RevertsOnDuplicateMint`.

### 6. Write-off during an active redeem corrupts indexes

**Fix (`src/Vault.sol`, `executeWriteOff`):**
```solidity
if (_reservedAssets[slot] > 0) revert AssetReserved();
```
Blocks write-off (and therefore `_retireSlot`'s index compaction) while the
slot has a reserved balance from an in-flight redeem leg. This is the
localized fix (option A from the review, not the larger
key-`RedeemState`-by-`assetId` refactor) — the admin/manager must wait for
the pending redeem on that asset to clear (via `swapAssetToUsdc` completing
that leg, then `claim`) before write-off can proceed.

Regression test: `test_ExecuteWriteOff_RevertsWhileAssetIsReservedForActiveRedeem`
(deposits, deploys, requests a redeem so `reservedAt(0) > 0`, then asserts
`confirmWriteOff` reverts with `AssetReserved`).

---

## High — fixed (mechanical subset)

| Fix | Where | Detail |
|---|---|---|
| `ReentrancyGuard` | `Vault.sol` | Added OpenZeppelin `ReentrancyGuard`; `nonReentrant` on `genesisDeposit`, `deposit`, `requestRedeem`, `claim`, `swapUsdcToAsset`, `swapAssetToUsdc`, `executeRebalance` — every entry point that calls out to `executeSwap` (and therefore a caller-supplied V4 pool/hook) or moves user funds. |
| Zero allowances after swap | `Vault.sol` | All three `executeSwap` call sites (`swapUsdcToAsset`, `swapAssetToUsdc`, both legs of `executeRebalance`) now reset the router approval to 0 immediately after the swap call returns. Closes the residual-allowance pull risk combined with `Swap_mod.executeSwap` being public. |
| `etfCreationAuthority` required | `ZenoIndexVault.sol` | Covered under Critical #4 above — `createVault` now reverts with `CreationGateNotSet` instead of defaulting open. |
| Oracle zero-address / rotation | `ZenoIndexVault.sol` | Constructor now rejects `priceOracle_ == address(0)`. Added `setPriceOracle(address)`, `onlySuperAdmin`-gated, emitting `PriceOracleSet`, so a bad oracle can be rotated without redeploying the factory. **Partial fix only** — no staleness/bounds checking was added; that remains open (see Not fixed). |

Regression tests: `test_Constructor_RevertsOnZeroPriceOracle`,
`test_SetPriceOracle_RotatesOracleAndRejectsZero`,
`test_SwapUsdcToAsset_ZeroesRouterAllowanceAfterSwap`. Reentrancy itself
isn't exercised by a hostile-hook test in this pass (no malicious-hook
fixture exists yet); the guard's presence is structural (compiles against
`ReentrancyGuard`, `nonReentrant` visible in the diff) rather than
behaviorally proven by a new test.

---

## Not fixed (explicitly out of scope this pass)

Carried over from `PRE_MAINNET_REVIEW.md`, unchanged:

- Manager/operator rug via rebalance path — `isOperator` is still global
  across every vault; one leaked operator key still affects all vaults.
- Oracle freshness/bounds (staleness, zero, huge, decimal mismatch) — only
  zero-address-at-construction and rotation were added.
- Emergency controls remain incomplete (`isEmergency`/`paused`/`adminLocked`
  still don't gate swaps or rebalance).
- Redeem cannot be cancelled — no cancel/timeout path added.
- `previewDeposit` vs `maxShares` clamp desync, and the `clampedNet` vs
  `computeFeeSplit(clampedGross)` pending-vs-cash rounding gap — unchanged.
- Written-off tokens are still unswept (`test_NoSweepFunction_WrittenOffTokensStayInCustody`
  still documents this as intended-for-now behavior).
- `UniswapV4Adapter`'s admin can still attach arbitrary hooks.
- No oracle-enforced slippage floor was added to `Vault.sol`'s swap paths —
  per the earlier scoping decision, `minOut`/`minAssetOut` remain fully
  caller-supplied; only path-end correctness was enforced.
- All of "Testing — green, too thin for mainnet" beyond the 14 new
  regression tests: no fuzzing, no invariant tests, no pause/emergency
  matrix, no fee-on-transfer/rebasing coverage, `ZenoIndexVault` admin
  surface (two-step super-admin, `setAssetActive`, `setVaultEmergencyLock`)
  is still largely untested.

---

## Coverage after this pass

`forge coverage --ir-minimum`:

| File | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `src/Pricing.sol` | 100% | 100% | 60% | 100% |
| `src/Swap_mod.sol` | 100% | 83% | 20% | 100% |
| `src/Vault.sol` | 90% | 83% | 32% | 85% |
| `src/ZenoIndexVault.sol` | 69% | 64% | 22% | 58% |
| `src/adapters/UniswapV4Adapter.sol` | 85% | 86% | 29% | 71% |
| `src/libraries/VaultMath.sol` | 75% | 61% | 6% | 78% |
| **Total** | **81%** | **75%** | **27%** | **79%** |

Branch coverage moved from 21% → 27% and `ZenoIndexVault.sol` branch coverage
from 0% → 22% as a side effect of the new revert-path tests, but this pass
was not a coverage sprint — the testing gaps listed above are still open.

---

## Verdict

The 6 Critical, fund-safety-breaking bugs are closed, plus 4 mechanical High
items. **This does not clear the project for mainnet** — the un-fixed High
items (global operator scope, oracle freshness, incomplete emergency
controls, no redeem cancellation) and the testing gaps are still real gaps
per the original review, and an independent audit is still recommended before
any mainnet deploy, per `PRE_MAINNET_REVIEW.md`'s original operational
blockers (items 2–4 there are unaffected by this pass).
