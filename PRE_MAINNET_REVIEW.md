# Open issues — fix before mainnet

**Date:** 2026-09-23
**Verdict:** Do not deploy until these are closed.

---

## 1. `createVault` is permissionless

`src/ZenoIndexVault.sol` — `createVault`

Anyone can clone a vault, become its manager, and land it in `vaultClones`. A UI that enumerates the factory will list attacker vaults next to real ones.

**Fix:** Gate creation to super-admin (or a dedicated authority), or add an `official` flag only super-admin can set.

---

## 2. NAV is an unbounded admin price table

`src/ZenoIndexVault.sol` — `setPrice` / `setPriceWhole`

Super-admin sets every non-USDC price. `usdcOut == 0` is allowed. There is no heartbeat, max-age, or range check. A leaked or mistaken admin key can deflate NAV, mint cheap shares, then restore the price. Stale prices silently mis-value the basket.

**Fix:** Reject `usdcOut == 0`. Add freshness/bounds, or a TWAP/push oracle with a heartbeat.

---

## 3. Zero-output redeem freezes write-off and slot retire

`src/Vault.sol` — `requestRedeem` / `claim`

`requestRedeem` always increments `activeRedeemCount`. If every pro-rata amount and the pending-USDC carve round to 0, `claim` reverts `NothingToClaim` and never calls `_resetRedeem`. The user is stuck (`RedeemAlreadyPending`). `activeRedeemCount` stays `> 0`, so write-off and auto-retire are blocked for the whole vault.

**Fix:** Revert `ZeroAmount` when the carve and all swap amounts are zero, or add a cancel/`claim` path that clears a zero-output redeem.

---

## 4. Super-admin transfer is one-step and can split-brain

`src/AccessMaster.sol` — `setSuperAdmin`, inherited `grantRole` / `revokeRole` / `renounceRole`

A typo in `setSuperAdmin` is irreversible (no pending/accept). `grantRole(ADMIN_ROLE, B)` adds a second admin without updating `_superAdmin`. `ZenoIndexVault.onlySuperAdmin` keys off `_superAdmin()`; treasury/operators key off `ADMIN_ROLE`. `setSuperAdmin` only revokes `msg.sender`, so a leftover role holder survives a transfer started by the other.

**Fix:** Two-step transfer. Route `ADMIN_ROLE` only through `setSuperAdmin`. Keep `_superAdmin` and the role in lockstep.

---

## 5. Global operator has custody of every vault and the asset registry

`src/Vault.sol` — `onlyManager`  
`src/ZenoIndexVault.sol` — `onlySuperAdminOrOperator`

`isOperator` is protocol-wide. One leaked operator key can retarget, rebalance (`minOut = 0`, intermediate hops caller-supplied), pause, change fee recipients on every vault, and `createAsset` / `setAssetActive`.

**Fix:** Scope operators per vault. Enforce an oracle-based min-out floor on swap paths.

---

## 6. `setUsdcToken` after live vaults desyncs accounting

`src/ZenoIndexVault.sol` — `setUsdcToken`

Clones read `usdcToken` live. Changing it after deposits leaves old balances in the old mint while NAV/fees/swaps treat the new mint as the 1:1 peg.

**Fix:** Make `usdcToken` immutable, or revert if `totalVaults > 0`.

---

## 7. Emergency / pause do not halt swaps, rebalance, or `setPrice`

| Flag | Blocks | Still runs |
|---|---|---|
| `isEmergency` | `createVault` | deposits, redeems, swaps, rebalance, genesis, `setPrice` |
| `paused` / `adminLocked` | `deposit` | genesis, redeem, swaps, rebalance |

A bad price or router cannot be frozen without relying on the manager to stop calling.

**Fix:** Emergency/pause must halt swaps, rebalance, genesis, and `setPrice`.

---

## 8. Redeem cannot be cancelled

`src/Vault.sol` — `requestRedeem`

Shares burn first. A failed hop (or issue 3) leaves burned shares and reserved assets. No timeout.

**Fix:** Cancel or timeout that restores or settles the position.

---

## 9. `previewDeposit` disagrees with the share-cap clamp

`src/Vault.sol` — `previewDeposit` / `deposit`

Preview ignores `maxShares`. On the clamp path, `_recordPendingTargets(clampedNet)` can over-earmark vs `computeFeeSplit(clampedGross).netAmount`.

**Fix:** Apply the same clamp in preview. Record pending from the actual net cash kept.

---

## 10. Wind-down dust never retires the slot

`src/Vault.sol` — `executeRebalance`

Oracle-sized sell vs AMM fill leaves sub-drift-band dust. A second pass no-ops. Repeated rotations can fill all 20 slots → `SlotFull`.

**Fix:** Dust sweep or a retire path that does not require an exact zero balance.

---

## 11. Written-off tokens have no sweep

`src/Vault.sol` — `executeWriteOff`

Tokens stay in the vault. Recovery is reactivate + rebalance, which puts them back in NAV.

**Fix:** Super-admin sweep, or document as permanent lock.

---

## 12. V4 adapter allows arbitrary hooks

`src/adapters/UniswapV4Adapter.sol` — `setPool`

Any hook address is accepted. A hook can skew fills during vault swaps.

**Fix:** Allowlist hooks, or require `hooks == address(0)` unless explicitly set.

---

## 13. `executeSwap` is public

`src/ZenoIndexVault.sol` — `executeSwap`

Anyone can drive the router with arbitrary `from` / `to`. A leftover vault→router allowance plus a lazy-pulling router is a pull risk.

**Fix:** Restrict callers to registered vault clones.

---

## Also fix

- **SafeERC20** — `require(token.transferFrom(...))` breaks on tokens that return no data.
- **`setFeeRecipient(address(0))`** — allowed; fees can be burned or the transfer reverts.
- **Fee-on-transfer / rebasing** — `createAsset` does not reject them; accounting assumes 1:1 receipt.
- **Deploy** — `Deploy.s.sol` leaves `router == address(0)` and an empty price table. Set router and prices before any vault is created, or put them in the script.
- **Pin `solc`** in `foundry.toml`.
