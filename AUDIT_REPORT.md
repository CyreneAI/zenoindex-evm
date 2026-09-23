# ZenoIndex EVM: security audit of `src/`

**Date:** 2026-09-23
**Scope:** every file in `src/` (2,217 lines): `Vault.sol`, `ZenoIndexVault.sol`, `AccessMaster.sol`, `adapters/UniswapV4Adapter.sol`, `libraries/{VaultMath,Constants}.sol`, `tokens/{ShareToken,ERC20Minimal}.sol`, `interfaces/*`. `mocks/*` was read but is out of scope.
**Code state:** the uncommitted working tree on `main` (after `c1b89aa`). This includes the fixes described in `PRE_MAINNET_REVIEW.md`.
**Toolchain:** solc 0.8.26, `via_ir`, cancun, OpenZeppelin 5.7.0. `forge test`: 100/100 passing.
**Method:** manual line-by-line review. Every High finding and two of the Medium findings have a passing proof-of-concept in `test/AuditPoC.t.sol` (`forge test --match-test test_PoC -vv`).

## Summary

| ID | Severity | Title | PoC |
|---|---|---|---|
| H-1 | High | USDC from rebalance sales drops out of NAV and out of redeems | ✅ |
| H-2 | High | Super-admin alone can drain any vault, with no timelock | ✅ |
| H-3 | High | Deposits priced by a stale admin table while redeems pay in kind lets people arbitrage existing holders | n/a (design) |
| M-1 | Medium | `setTargetAllocations` accepts unpriced assets, so a 1-wei donation bricks deposits and rebalances | ✅ |
| M-2 | Medium | Any shareholder can block write-off and slot retirement forever | ✅ |
| M-3 | Medium | In-kind exit is all-or-nothing: one reverting token traps the whole redeem | none |
| M-4 | Medium | `maxPriceChangeBps` can be bypassed by calling `setPrice` repeatedly | none |
| M-5 | Medium | The manager can churn the portfolio, losing up to 3% per swap, with no rate limit | none |
| L-1 … L-7 | Low | see below | none |
| I-1 … I-6 | Info | see below | none |

---

## High

### H-1: USDC from rebalance sales drops out of NAV and out of redeems

**Where:** `Vault.totalNav` / `_quoteDeposit` / `requestRedeem`, `ZenoIndexVault.sumNav` (`ZenoIndexVault.sol:461`)

NAV is `sumNav(slots) + totalPendingUsdc`. `sumNav` counts the vault's USDC balance only when USDC is one of the slots. Without a USDC slot, NAV omits USDC that is not pending or escrowed. The same happens in `requestRedeem`, which pays out per slot. This USDC comes from:

- overweight sales in `_rebalanceTowardTarget` and wind-down sales in `executeRebalance`,
- pending USDC that `_retireSlot` drops when a slot retires or is written off,
- partial-fill refunds from the adapter (`UniswapV4Adapter.sol:187`),
- rounding dust from `allocationSlice`.

**PoC:** `test_PoC_RebalanceSaleUnderstatesNav` shows that a reweight from 60/40 to 10/90, followed by one sell, drops `totalNav` from **99,940 USDC to 49,980 USDC**. Meanwhile **49,942 USDC** sits in the vault uncounted.

**Impact:**
- **Cheap shares:** anyone who deposits between the sell and the matching buy gets about 2x the shares they should. This is easy to automate by watching for `RebalanceExecuted(..., wasSell=true)`.
- **Lost value for redeemers:** anyone who redeems in that window gives up their share of the uncounted USDC to the holders who remain.
- **Permanent loss:** if the manager never buys back, the uncounted USDC stays uncounted.

`PRE_MAINNET_REVIEW.md` lists this as "still open", but the PoC shows the impact is far larger than "NAV is understated in a window".

**Fix:** treat `usdcBal − totalPendingUsdc − vaultRedeemEscrowTotal` (minus any USDC-slot reservation) as an implicit USDC leg. Count it in `sumNav`, and give redeemers their pro-rata share of it in `requestRedeem` (credit it to escrow the way the USDC slot's share is credited). Better still, make it structural: every vault has an implicit cash slot.

### H-2: Super-admin alone can drain any vault, with no timelock

**Where:** `ZenoIndexVault.setVaultOperator` → `Vault.proposeWriteOff` → `ZenoIndexVault.confirmWriteOff` → `ZenoIndexVault.sweepWrittenOff`

The write-off flow is meant as a two-party check: the manager proposes and the super-admin confirms. But the super-admin can make itself a vault operator, and operators have manager powers, including `proposeWriteOff`. `sweepWrittenOff` then sends the balance to **any** `to`.

**PoC:** `test_PoC_SuperAdminUnilateralDrain` shows the super-admin sweeping 100% of both tokenA and tokenB from a funded vault to itself. `totalNav()` ends at 0. The only thing that can stop it is an open redeem (see M-2).

**Impact:** anyone holding the super-admin key, or anyone who compromises it, can take every non-USDC asset in every vault: one transaction to make itself an operator, then three per asset (propose, confirm, sweep). No timelock gives holders a chance to exit first.

**Fix (combine as needed):**
- Only `vaultManager` can call `proposeWriteOff` / `proposeReactivate`, not per-vault operators.
- Remove the arbitrary `to` from `sweepWrittenOff`. Either sell the asset to USDC inside the vault, or pay it pro-rata to holders.
- Put `confirmWriteOff`, `sweepWrittenOff`, `setSwapRouter`, `setMaxPriceChangeBps`, and `setMaxPriceAge` behind a timelock (for example 48h), and make the super-admin a multisig.

### H-3: Deposits priced by a stale admin table while redeems pay in kind lets people arbitrage existing holders

**Where:** `_quoteDeposit` (priced by `ZenoIndexVault._quote`) vs `requestRedeem` (pro-rata of real balances)

Deposits mint shares at the price table's value. Prices can be up to `maxPriceAge` old (1 day by default), and the next update is visible in the mempool. Redemptions pay a pro-rata share of the **actual tokens**, which are worth their market value. So when the market is above the table:

1. Deposit USDC. You receive shares priced against undervalued assets, so you get too many.
2. Redeem. You receive a pro-rata share of the real assets and pending USDC, and swap or take them in kind at market.

Profit ≈ (market − table)/table − `depositFeeBps` (can be **0**) − `redeemFeeBps` (≥ 0.5%) − swap cost. With a volatile basket and a daily keeper, gaps above 1% are routine. Front-running a large `setPrice` transaction is risk-free. Every such cycle dilutes existing holders.

**Fix:** use a live, manipulation-resistant price for deposits: Chainlink/Pyth with a short heartbeat, or a V4 TWAP compared against the table. Other options: make `maxPriceAge` minutes, not a day; set a minimum deposit fee well above the expected table error; or add a minimum holding period / redeem delay for newly minted shares.

---

## Medium

### M-1: `setTargetAllocations` accepts unpriced assets, so a 1-wei donation bricks deposits and rebalances

**Where:** `Vault.setTargetAllocations` (`Vault.sol:485`); compare `ZenoIndexVault.createVault` (`ZenoIndexVault.sol:300`)

`createVault` requires a price for every non-USDC asset. `setTargetAllocations` checks only `exists` and `active`. `sumNav` skips slots with a zero balance (`if (free == 0) continue;`), so the gap stays hidden until someone sends that token to the vault. After that, every `_sumNav` call reverts with `NoPrice`: `deposit`, `previewDeposit`, `totalNav`, and `executeRebalance` toward a target. `swapUsdcToAsset` into the new asset also reverts, because `swapFloor` has no price to use.

**PoC:** `test_PoC_UnpricedAssetDonationBricksDeposits`.

**Fix:** in `setTargetAllocations`, and in `executeReactivate`, require `priceDen(mint) != 0 || mint == usdc`, the same check `createVault` uses. Longer term, make NAV fail per asset instead of failing the whole calculation (see L-1).

### M-2: Any shareholder can block write-off and slot retirement forever

**Where:** `activeRedeemCount` guard in `executeWriteOff` (`Vault.sol:578`) and `executeRebalance` (`Vault.sol:545`); `assert` in `_retireSlot`

Write-off and retirement require `activeRedeemCount == 0` for the **whole vault**. This is because `_retireSlot` compacts slot indices, which would corrupt any open `RedeemState`. Opening a redeem costs almost nothing: redeem fees round to 0 on tiny amounts. An attacker with a few addresses can always keep one redeem open, and can reopen in the same block after `claimInKind` or `forceSettleRedeem`. Even without an attacker, a busy vault rarely reaches zero open redeems, because every redeem takes at least two transactions.

**PoC:** `test_PoC_OpenRedeemBlocksWriteOff`. `confirmWriteOff` reverts `AssetReserved`, and still reverts after the griefer settles and reopens.

**Impact:** a dead or delisted asset cannot be written off. Its stale price keeps reverting NAV (see M-1 / L-1), so deposits and rebalances stay halted. Winding-down slots never free up, and the vault eventually runs out of slots (`SlotFull`).

**Fix:** remove the root cause. Either key `RedeemState` legs by `assetId` instead of slot index, or stop compacting: leave retired slots as tombstones and reuse them. Then retirement only needs `_reservedAssets[slot] == 0`, which is exactly the condition that matters.

### M-3: In-kind exit is all-or-nothing: one reverting token traps the whole redeem

**Where:** `Vault._settleInKind` (`Vault.sol:736-747`)

`claimInKind` and `forceSettleRedeem` send every unswapped leg and then the USDC escrow in a single loop. If any one `safeTransfer` reverts, the whole exit reverts. Causes include a paused token, a blacklisted recipient, or a transfer-restricted token. The tokenized equities that Robinhood Chain is built for commonly have allowlists. When that happens:

- the user cannot reach their USDC escrow or the other legs, and
- the redeem stays open forever, so M-2 becomes permanent for the whole vault.

**Fix:** settle each leg independently. Record a failed leg as a claimable per-asset balance, with a pull-based `withdrawInKind(asset)`, and then close the redeem. Pay the USDC escrow even when an asset leg fails.

### M-4: `maxPriceChangeBps` can be bypassed by calling `setPrice` repeatedly

**Where:** `ZenoIndexVault._setPrice` (`ZenoIndexVault.sol:498`)

The bound compares each update only with the previous stored price, and there is no cooldown. Four calls in one block move a price by 2.07x (1.2⁴). `setMaxPriceChangeBps(0)` removes the bound instantly. The review describes this rail as protection against a bad price push, but it does not stop a compromised or careless key. Combined with H-3, a bad price mints shares at any price the key chooses.

**Fix:** allow one update per token per N minutes, or bound each update against a time-weighted reference price. Put changes to the bound itself behind the H-2 timelock.

### M-5: The manager can churn the portfolio, losing up to 3% per swap, with no rate limit

**Where:** `setTargetAllocations`, `executeRebalance`, `swapUsdcToAsset`; `swapFloor`

The manager, or any per-vault operator, picks the path, `minOut`, and timing of every vault swap. The only protection is the price-table floor: table price minus `maxSwapSlippageBps` (3% by default). Target changes have no timelock or rate limit. A malicious manager can therefore cycle the targets, for example A→B then B→A, and sandwich each vault swap in the registered V4 pools. That extracts up to about 3% of the traded amount per swap, repeatedly. Stale table prices (H-3) add to what can be taken.

**Fix:** lower the default floor (for example 50–100 bps for liquid pairs). Add a cooldown or timelock on `setTargetAllocations`. Cap rebalance turnover per epoch. Optionally, remove the manager's choice of intermediate hops.

---

## Low

- **L-1: One bad price stops the whole vault.** `sumNav` reverts if **any** slot's price is stale or unset. So a single keeper miss on one token halts deposits and rebalances for every vault holding it. The swap floor does the same to swaps whenever the market moves more than 3% away from the table: in a crash, sells revert, and redeemers must fall back to in-kind. *Fix:* monitoring and alerting on the keeper, a shorter keeper interval, and consider letting an admin set a per-asset "valuation override / zero" for dead assets.
- **L-2: Write-off and reactivate proposals never expire and cannot be cancelled.** `pendingWriteOff[id]` stays `true` indefinitely, so a proposal from months ago can still be confirmed. *Fix:* store a timestamp and add an expiry and a `cancelWriteOff`.
- **L-3: A global operator can force every vault to wind down an asset.** `setAssetActive(id, false)` makes `setTargetAllocations` revert for any list containing `id`, so managers must drop it. Global operators are meant to have only registry powers, but this reaches into every vault's allocation. *Fix:* check `active` only for assets newly added to a vault.
- **L-4: USDC-slot drift cannot be rebalanced directly.** For a USDC slot, `_rebalanceTowardTarget` builds a USDC→USDC path, which always reverts `PoolNotSet`. *Fix:* return early for `mint == usdc` and document that USDC weight is fixed by buying or selling the other slots.
- **L-5: Adapter admin transfer is one step.** `UniswapV4Adapter.setAdmin` transfers immediately. The adapter admin decides which contracts may call `swap` and which pools/hooks are used, so it deserves the same two-step flow as `AccessMaster`.
- **L-6: The vault manager cannot be rotated.** There is no `setVaultManager`. A lost manager key can only be worked around with super-admin-granted operators, which gives the super-admin the leverage used in H-2.
- **L-7: Share precision is coarse at high baselines.** Shares have 6 decimals. With `baselineSharePrice` at the maximum ($100k), genesis mints 10 raw units, and each raw unit is worth $0.10. Each deposit then rounds away up to one unit's value, and deposits with `minSharesOut = 0` are exposed. *Fix:* use 18-decimal shares or lower `MAX_BASELINE_SHARE_PRICE`.

## Informational

- **I-1:** Error handling mixes `require` strings (`"PATH_START"`, `"PATH_ENDS"`, `"IDX"`, `"LEN"`, `"PARTIAL_MID_HOP"`, `"ONLY_VAULT"`) with custom errors. `swapUsdcToAsset` and `swapAssetToUsdc` index `path[0]` without the length check that `_requirePath` performs.
- **I-2:** No event in `Vault.sol` has `indexed` parameters (for example `Deposit.user`, `RequestRedeem.user`). This makes off-chain indexing expensive.
- **I-3:** `setPaused`, `setFeeRecipient`, `setVaultEmergencyLock`, `setVaultOperator`'s effect, and `setAssetActive` emit no Vault-level events, or none that indexers can easily attribute.
- **I-4:** `ERC20Minimal` allows transfers to `address(0)`, so shares can be burned by mistake. `approve` has the usual race condition. The share token has no `permit`.
- **I-5:** When a slot is reweighted to 0% it keeps its `_usdcTargetAmount`, so the manager can still buy into an asset that is winding down.
- **I-6:** Stale comments refer to the Solana port (`fee_split.rs`, "Token-2022 share mint stand-in") and to the removed `NavCalculation.sol` / `SwapExecutor.sol`.

## Checked and found sound

- **Reentrancy guard in clones.** OZ 5.7's `ReentrancyGuard` uses a namespaced slot, and an uninitialized value of 0 counts as not entered, so clones are protected. Every external value-moving function in `Vault` is `nonReentrant`.
- **Initialization.** The implementation calls `_disableInitializers()`. Each clone is created and `init`-ed in the same transaction, so `init` cannot be front-run.
- **`executeSwap` access.** Only registered clones can call it, and only with `from == msg.sender`. The adapter's `swap` accepts only authorized callers. `unlockCallback` accepts only the `PoolManager`. The v4 `sync → transfer → settle → take` sequence is correct.
- **Swap accounting.** Output is measured by balance change, not the router's reported amount. The router's approval is set to exactly `amountIn` and reset to 0 afterwards.
- **Redeem bookkeeping.** `_reservedAssets`, `vaultRedeemEscrowTotal`, and the pending carve stay consistent across `requestRedeem`, `swapAssetToUsdc`, `claim`, and `_settleInKind`. The USDC-slot double count is fixed.
- **`AccessMaster`.** `ADMIN_ROLE` and `_superAdmin` cannot drift apart, and the two-step transfer is correct.
- **Share-cap clamp.** `_quoteDeposit` never mints more than `maxShares`, and `previewDeposit` matches `deposit`.

## Recommended order of work

1. **H-1:** count uncounted USDC in NAV and in redeems. This is exploitable by anyone as soon as the first rebalance sale happens.
2. **H-3 + M-4:** replace or guard deposit pricing with a live oracle, and add a price-update cooldown.
3. **H-2:** restrict who can propose a write-off, fix the sweep destination, and put admin actions behind a timelock and multisig.
4. **M-2 + M-3:** stop compacting slots, and settle in-kind legs independently.
5. **M-1:** add the price check to `setTargetAllocations`. It is a one-line fix.
6. Then M-5, the Low findings, and the Info items.

*Limitations: manual review only. No fuzzing or formal verification, and no review of `lib/`, the deploy script, or off-chain keepers. The Uniswap V4 hook allowlist and pool configuration are trusted to the adapter admin.*
