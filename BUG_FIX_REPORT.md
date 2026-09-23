# ZenoIndex vault: bug fix report

**Date:** 2026-09-23
**Base commit:** `c1b89aa` (changes are uncommitted on `main`)
**Tests:** 100 / 100 passing (was 77)
**Compiler:** solc 0.8.26 (pinned)
**Mainnet:** blocked by 1 open item (O-1)

This report covers what was broken in the vault contracts, why, what changed, and the test that covers each fix. It covers every point in `PRE_MAINNET_REVIEW.md` plus one bug found while fixing them.

---

## Summary

- **8** bugs fixed (the code broke its own invariants)
- **10** design and trust-model changes
- **23** new regression tests
- **1** open issue found, not yet fixed

| ID | Bug | Severity | Status |
|---|---|---|---|
| B-1 · #3 | Dust redeem permanently freezes write-off and slot retire | High | Fixed |
| B-2 · new | USDC basket slot double-counted in redeems | High | Fixed |
| B-3 · #13 | Adapter `swap` spends any account's allowance | Medium | Fixed |
| B-4 · #4 | Super-admin record and `ADMIN_ROLE` can diverge | Medium | Fixed |
| B-5 · #10 | Wind-down dust stops slots from retiring (griefable) | Medium | Fixed |
| B-6 | Non-standard ERC-20s break transfers (no SafeERC20) | Medium | Fixed |
| B-7 · #9 | `previewDeposit` ignores the share cap; clamp over-earmarks | Low | Fixed |
| B-8 | `setFeeRecipient(address(0))` accepted | Low | Fixed |
| O-1 | Spare USDC missing from NAV without a USDC slot | High | **Open** |

**Severity key:**
- **High:** users can lose value, or anyone can freeze the vault.
- **Medium:** needs a specific token, key or configuration, or causes a liveness problem that can be recovered.
- **Low:** wrong numbers in views, or an input check only an admin can trip.

"#n" refers to the numbered point in `PRE_MAINNET_REVIEW.md`.

---

## Bugs fixed

### B-1 · Dust redeem permanently freezes write-off and slot retire (High, review #3)

`src/Vault.sol`: `requestRedeem` / `claim`

- **Cause:** `requestRedeem` always opened a redeem and incremented `activeRedeemCount`. For a tiny share amount, every pro-rata leg and the pending-USDC carve round to 0. `claim` then reverted `NothingToClaim` before reaching `_resetRedeem`, so the redeem could never close.
- **Impact:** anyone holding 1 wei of shares could call `requestRedeem(1)` and leave `activeRedeemCount` above 0 forever. Write-off and slot retirement both require it to be 0, so both were blocked for the whole vault, permanently.
- **Fix:** a redeem that would pay nothing is rejected. `claim` now closes a redeem even when its escrow is 0. The in-kind settlement and 7-day force-settle (review #8) also mean an abandoned redeem can always be cleared.
- **Test:** `test_RequestRedeem_RevertsWhenEverythingRoundsToZero`

```diff
  // requestRedeem, before shares are burned
+ if (usdcCredit == 0 && !anySwapLeg) revert ZeroAmount();

  // claim
- uint256 grossUsdc = redeemUsdcBal[msg.sender];
- if (grossUsdc == 0) revert NothingToClaim();
+ (uint256 grossUsdc, VaultMath.FeeSplit memory fee) = _payOutEscrow(msg.sender); // 0 is fine
  _resetRedeem(rs);
```

### B-2 · USDC basket slot double-counted in redeems (High, found while fixing)

`src/Vault.sol`: `requestRedeem`

- **Cause:** the code supports USDC as a basket asset, but `requestRedeem` treated the vault's entire USDC balance as that slot's free balance. That balance includes USDC waiting to be deployed and USDC owed to other redeemers. `sumNav` already subtracts both; `requestRedeem` did not.
- **Impact:** a redeemer received their share of pending USDC twice: once in the USDC-slot amount and again through the pending carve. They also took part of other users' escrow. In the regression test the overpayment was about $50 on a $100 deposit. Unwinding that slot also needed a pointless USDC → X → USDC round-trip swap.
- **Fix:** a new `_freeBalance` helper excludes pending and escrowed USDC from a USDC slot. The slot's share is credited straight to escrow, with no swap leg.
- **Test:** `test_RequestRedeem_UsdcSlotExcludesPendingAndEscrow`

```diff
  function _freeBalance(uint8 i, address usdc) internal view returns (uint256 free, address mint)
    uint256 locked = _reservedAssets[i];
+   if (mint == usdc) locked += totalPendingUsdc + vaultRedeemEscrowTotal;
    free = bal > locked ? bal - locked : 0;

  // requestRedeem
+ if (isUsdcSlot[i]) { usdcCredit += amounts[i]; amounts[i] = 0; }
```

### B-3 · Adapter `swap` spends any account's allowance (Medium, review #13)

`src/adapters/UniswapV4Adapter.sol`: `swap` · `src/ZenoIndexVault.sol`: `executeSwap`

- **Cause:** the review flagged `ZenoIndexVault.executeSwap` as public, but the real hole was one layer down. `UniswapV4Adapter.swap` was public and did `transferFrom(from, …)` with a caller-chosen `from`. Restricting `executeSwap` alone would not have closed it.
- **Impact:** anyone could call `swap(path, amount, 0, victim, attacker)` and route a victim's tokens to themselves, as long as the victim had approved the adapter. Vaults reset their approval to 0 after every swap, so vault funds were not exposed, but any other account approving the adapter was.
- **Fix:** the adapter only accepts callers the admin authorises (`setAuthorizedCaller`). `executeSwap` only accepts registered vault clones and requires `from == msg.sender`.
- **Tests:** `test_swap_revertsForUnauthorizedCaller_evenWithVictimAllowance`, `test_ExecuteSwap_RevertsForNonClone`

```diff
  // UniswapV4Adapter.swap
+ if (!isAuthorizedCaller[msg.sender]) revert NotAuthorizedCaller();

  // ZenoIndexVault.executeSwap
+ if (!isVaultClone[msg.sender]) revert NotVaultClone();
+ if (from != msg.sender) revert InvalidSwapSource();
```

### B-4 · Super-admin record and `ADMIN_ROLE` can diverge (Medium, review #4)

`src/AccessMaster.sol`: `setSuperAdmin`, inherited `grantRole` / `revokeRole` / `renounceRole`

- **Cause:** admin identity was stored twice: `_superAdmin` and the OpenZeppelin `ADMIN_ROLE`. Only `setSuperAdmin` kept them in sync. The inherited `grantRole`, `revokeRole` and `renounceRole` changed the role without touching `_superAdmin`.
- **Impact:** the two could point at different people. `ZenoIndexVault` checks `superAdmin()`, while treasury and operator changes check the role. A second role holder could survive an admin transfer. A renounced admin kept super-admin powers in `ZenoIndexVault`.
- **Fix:** the three inherited functions revert for `ADMIN_ROLE`. The transfer is now two steps (`setSuperAdmin` proposes, `acceptSuperAdmin` completes), so a typo can be corrected by proposing again.
- **Tests:** `test_AdminRole_CannotBeGrantedRevokedOrRenouncedDirectly`, `test_AcceptSuperAdmin_*`, `test_SetSuperAdmin_TypoIsRecoverableByReproposing`

### B-5 · Wind-down dust stops slots from retiring (Medium, review #10)

`src/Vault.sol`: `executeRebalance`

- **Cause:** a 0%-weight slot was sold down by a delta sized from the price table, but the pool fills at its own price, so dust remained. Retiring needed a balance of exactly 0, and the drift band then turned every later call into a no-op.
- **Impact:** slots never retired. Anyone could also donate 1 wei of the token to keep a slot open. Repeated rotations fill all 20 slots, after which new assets fail with `SlotFull`.
- **Fix:** a 0%-weight slot sells its *whole* free balance. It retires once what's left is worth at most `RETIRE_DUST_USDC` ($0.001), so donated dust is ignored. The retire check now runs even when no trade happens.
- **Tests:** `test_ExecuteRebalance_WindDownSellsDownToSubDriftBandDust`, `test_ExecuteRebalance_DonatedDustDoesNotBlockRetire`

### B-6 · Non-standard ERC-20s break transfers (Medium, review "Also fix")

`src/Vault.sol` · `src/adapters/UniswapV4Adapter.sol`

- **Cause:** transfers used `require(token.transfer(...))` and plain `approve`. Tokens like USDT return no value, so these calls revert.
- **Impact:** any such token in a basket would make deposits, swaps and claims revert.
- **Fix:** OpenZeppelin `SafeERC20` throughout (`safeTransfer`, `safeTransferFrom`, `forceApprove`). Swap outputs are now measured by the vault's balance change, not the router's reported amount.

### B-7 · `previewDeposit` ignores the share cap; clamp over-earmarks (Low, review #9)

`src/Vault.sol`: `previewDeposit` / `deposit`

- **Cause:** preview and deposit each did their own maths, and only deposit applied the fixed-vault share cap. On the capped path, pending USDC was recorded from the clamped net, which rounding can put 1 unit above the net actually kept.
- **Impact:** the UI could show more shares than a capped deposit mints, and pending USDC could be over-recorded by dust.
- **Fix:** one shared `_quoteDeposit` used by both. Pending is recorded from `fee.netAmount`.
- **Test:** `test_PreviewDeposit_MatchesClampedDeposit`

### B-8 · `setFeeRecipient(address(0))` accepted (Low, review "Also fix")

`src/Vault.sol`: `setFeeRecipient`

- **Impact:** fees could be burned. With tokens that refuse transfers to address 0, every deposit and claim would revert.
- **Fix:** reverts `ZeroAddress`.
- **Test:** `test_SetFeeRecipient_RevertsOnZero`

---

## Design and trust-model changes

Before these changes the code did what it was written to do. These change the rules to make the protocol safer.

| Review | Change | Test |
|---|---|---|
| #1 | Only super-admin or allowlisted accounts (`setVaultCreator`) can create vaults. `createVault` also requires a router and a price for every basket asset. | `test_CreateVault_RevertsForNonAllowlistedCaller`, `…WhenAssetHasNoPrice`, `…WhenNoRouterSet` |
| #2 | Zero prices rejected. Quotes revert `StalePrice` after 1 day. A single update can't move a price more than 20%. | `test_SetPrice_RejectsZeroAndOversizedMove`, `test_StalePrice_BlocksDepositUntilRefreshed` |
| #4 | Two-step super-admin transfer (see B-4). | `AccessMaster.t.sol` |
| #5 | Operators scoped to one vault (`setVaultOperator`). Every swap's minimum output is raised to the price-table quote minus 3%. | `test_Operators_AreScopedPerVault`, `test_Swap_PriceTableFloorOverridesZeroMinOut` |
| #6 | `setUsdcToken` reverts once any vault exists. | `test_SetUsdcToken_RevertsOnceAVaultExists` |
| #7 | Emergency halts vault creation, genesis, deposits, all swaps and rebalances. Pause and lock also halt the manager's swaps. `setPrice` deliberately stays open so a bad price can be fixed while frozen. | `test_Emergency_HaltsDepositsAndSwapsButNotInKindExit`, `test_Pause_HaltsManagerSwapsAndRebalance` |
| #8 | `claimInKind()` lets a redeemer exit with unswapped assets in kind. `forceSettleRedeem(user)` is open to anyone after 7 days. | `test_ClaimInKind_SettlesUnswappedLegsInAsset`, `test_ForceSettleRedeem_OnlyAfterTimeout` |
| #11 | Super-admin `sweepWrittenOff`. USDC can't be written off. | `test_WriteOff_LeavesTokensInCustodyUntilSwept` |
| #12 | V4 pools only accept hooks on an allowlist (`setHookAllowed`). | `test_setPool_rejectsHookUntilAllowlisted` |
| Also | `solc` pinned to 0.8.26 (cancun). The deploy script can set asset prices and lists the post-deploy steps. | – |

**Partly addressed: fee-on-transfer and rebasing tokens.** Contracts can't reliably detect them, and a token's fee can be switched on after listing. These tokens now make swaps revert instead of silently skewing the accounting, and `createAsset` documents them as unsupported. Asset listing still has to screen them out off-chain.

---

## Still open

### O-1 · Spare USDC missing from NAV without a USDC slot (High)

`src/Vault.sol`: `_sumNav` / `totalNav` · `src/ZenoIndexVault.sol`: `sumNav`

NAV is `sumNav(slots) + totalPendingUsdc`. USDC from a rebalance sale, or pending USDC dropped when a slot retires or is written off, stays in the vault but is counted nowhere unless the vault has a USDC slot. Between an overweight sale and the matching buy, NAV is understated. A deposit in that window mints shares too cheaply, at existing holders' expense.

**Proposed fix:** count the vault's USDC balance minus `totalPendingUsdc + vaultRedeemEscrowTotal` in NAV, whether or not a USDC slot exists. Not applied yet, because it changes how NAV is defined and needs sign-off.

---

## Deployment changes

After deploying, and before anyone creates a vault, the admin must:

1. Authorise the factory on the adapter: `UniswapV4Adapter.setAuthorizedCaller(zenoIndexVault, true)`.
2. Set the router: `setSwapRouter(adapter)`.
3. Price every basket asset with `setPriceWhole`, or set `ASSET_i_PRICE` in the deploy script.
4. Allow vault creators: `setVaultCreator(manager, true)`.
5. Run a keeper that refreshes prices at least daily, or deposits and rebalances halt with `StalePrice`.

---

## Verification

- `forge test`: 100 passed, 0 failed across 4 suites (was 77). Every fix has at least one regression test.
- Old tests that asserted the previous behaviour were rewritten: the one-step admin transfer, "dust never retires a slot", and "written-off tokens have no sweep".
- B-2's test fails on the old code (about $50 of overpayment). B-1's test confirms every leg rounds to 0.
- `script/check-readme-src-docs.sh` fails six checks on removed contracts (`NavCalculation.sol`, `SwapExecutor.sol`). It fails identically on base commit `c1b89aa`, so these changes didn't cause it.

**Files changed (15, +1,149 / −315):** `AccessMaster.sol`, `Vault.sol`, `ZenoIndexVault.sol`, `UniswapV4Adapter.sol`, `IVault.sol`, `IZenoIndexVault.sol`, `Constants.sol`, `Deploy.s.sol`, `foundry.toml`, `.env.example`, `README.md`, `PRE_MAINNET_REVIEW.md`, and three test files.
