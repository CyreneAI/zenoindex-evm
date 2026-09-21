# Pre-mainnet review: testing and vulnerabilities

**Date:** 2026-09-21
**Scope:** `src/`, `script/Deploy.s.sol`, `test/`
**Toolchain:** Foundry 1.8.3, solc 0.8.26
**Verdict:** Do not deploy this to mainnet.

The 35-test suite is green. It only covers happy paths. Several paths let a caller take or freeze vault funds, and the deploy script ships the mock stack.

Compiled and ran the suite: **35 passed, 0 failed**. Coverage is 79% of lines and **21% of branches**. `Vault.sol` is at 26% branch coverage; `ZenoIndexVault.sol` is at 0% branch coverage.

This is a pre-deploy pass, not a substitute for an independent audit.

---

## Critical — fix before any real funds

### 1. Anyone can spend pending USDC down an arbitrary swap path

`swapUsdcToAsset` is permissionless, checks only `path[0] == USDC`, and takes `minAssetOut` from the caller.

```solidity
// src/Vault.sol:410
function swapUsdcToAsset(uint8 assetIndex, address[] calldata path, uint256 minAssetOut) external {
    if (assetIndex >= numAssets) revert InvalidAssetIndex();
    uint256 amount = _usdcTargetAmount[assetIndex];
    if (amount == 0) return;

    address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
    require(path[0] == usdc, "PATH_START");
    // ...
    uint256 assetOut = ISwapModLike(swapModAddr).executeSwap(path, amount, minAssetOut, address(this), address(this));
```

A caller can:

- Route the vault's undeployed USDC to the wrong token (any registered pair).
- Set `minAssetOut = 0` and sandwich the trade.

That USDC belongs to all LPs. `swapAssetToUsdc` correctly requires `path[last] == USDC`; this function does not do the matching check on the output mint.

**Fix:** Require `path[path.length - 1]` to be the slot's mint. Enforce a minimum out from the oracle (for example 99% of `quoteUsdc` inverted). Restrict the caller to the manager/operator, or both.

### 2. Rebalance buys spend redeem escrow and pending USDC

Underweight `executeRebalance` treats the vault's entire USDC balance as free:

```solidity
// src/Vault.sol:561
uint256 deltaValueUsdc = ((targetBps - currentBps) * nav) / Constants.BPS_DENOM;
uint256 usdcFree = ERC20Minimal(usdc).balanceOf(address(this));
uint256 buyAmount = deltaValueUsdc < usdcFree ? deltaValueUsdc : usdcFree;
```

That balance includes `totalPendingUsdc` (earmarked for other legs) and `vaultRedeemEscrowTotal` (owed to redeemers). The buy does not reduce those counters. Later `swapUsdcToAsset` or `claim` then spends money that is already gone. An honest rebalance during pending redemptions is enough to brick `claim`.

**Fix:** `usdcFree = balance - totalPendingUsdc - vaultRedeemEscrowTotal`. Also require `path[last]` to be the target mint (sells) or USDC (buys).

### 3. Deploy script is the mock stack, including the mainnet comment

`script/Deploy.s.sol` deploys `MockERC20`, `MockPriceOracle`, and `MockSwapRouter`, then wires them in. The header tells the operator to use the same script on chainId 4663.

Those mocks are writable by anyone:

- `MockPriceOracle.setPrice` / `setPriceWhole` — set NAV to whatever you want, mint cheap shares, raise the price, redeem.
- `MockSwapRouter.setRate` — set the USDC→asset rate to dust and drain pending USDC through issue 1.

There is no production script that takes real USDC, a real oracle, and `UniswapV4Adapter`.

### 4. Fee caps in `Constants` are never applied

`MAX_DEPOSIT_FEE_BPS = 600`, `MIN_REDEEM_FEE_BPS = 50`, `MAX_REDEEM_FEE_BPS = 1000` exist only as unused constants. `createVault` / `init` store whatever `uint16` the creator passes. Default `etfCreationAuthority` is `address(0)`, so anyone can create a vault with a 100% deposit fee.

**Fix:** Enforce the constants in `init`. Keep `etfCreationAuthority` set before the factory is used.

### 5. Duplicate asset IDs double-count NAV

`init` writes `assetIds` into parallel slots with no uniqueness check. `Pricing.sumNav` values `balanceOf` per slot. The same token in two slots is counted twice, so share minting and redemptions are wrong. `createAsset` also allows the same mint under two ids.

### 6. Write-off during an active redeem corrupts indexes

`executeWriteOff` calls `_retireSlot` even when `_reservedAssets[slot] > 0`. Compaction shifts another asset into that index while the redeemer's `RedeemState` still holds the old amounts and `numAssets`. `swapAssetToUsdc` then swaps the wrong token or reverts `InvalidAssetIndex`, and `claim` can never finish because `assetSwapped[i]` stays false. Shares are already burned.

**Fix:** Block write-off (and slot retirement) while any slot has reserved balance, or key redeem state by `assetId` instead of index.

---

## High

| Issue | Where | What happens |
|---|---|---|
| No `ReentrancyGuard` | `Vault` deposit / redeem / swap / rebalance | State is updated after `executeSwap`. A V4 hook on a registered pool can reenter while `_usdcTargetAmount` and `assetSwapped` are still old. |
| Manager/operator rug via rebalance path | `executeRebalance` | Only `path[0]` is checked. `isOperator` is global across every vault. One leaked operator key can sell all vaults into a pool the attacker controls. |
| Oracle has no freshness or bounds | `IPriceOracle.quoteUsdc`, constructor | Spot (or mock) prices are trusted raw. There is no `setPriceOracle`, so a bad oracle cannot be rotated. Constructor also allows `priceOracle_ = address(0)`. |
| Emergency controls are incomplete | `setEmergency`, `paused`, `adminLocked` | Emergency only blocks `createVault`. Pause and `adminLocked` only block `deposit`. Swaps, rebalance, and genesis still run. |
| Redeem cannot be cancelled | `requestRedeem` | Shares burn first. If a hop has no liquidity, the user is stuck with burned shares and reserved assets. |
| `previewDeposit` ignores the share cap | `Vault.sol:304` | Preview and `deposit` disagree on Fixed vaults near `maxShares`. |
| Share-cap clamp vs fees can desync pending | `Vault.sol:276-299` | `_recordPendingTargets` uses `clampedNet`; actual USDC kept is `computeFeeSplit(clampedGross).netAmount`. Integer division can over-earmark pending vs cash. |
| Written-off tokens are stuck | `executeWriteOff` | No sweep. Test `test_NoSweepFunction_WrittenOffTokensStayInCustody` documents this. |
| `setTargetAllocations` skips registry checks | `Vault.sol:469` | Manager can add a missing `assetId`. `getAsset` returns `mint = address(0)` and NAV/deposit revert. |
| Approvals left on the router | every swap | `approve(router, amount)` is never cleared. A router that pulls less than `amount` leaves a residual allowance. |
| `Swap_mod.executeSwap` is public | `Swap_mod.sol:39` | Combined with a residual vault→router allowance, anyone can pull vault tokens by calling the adapter with `from = vault`. |

`UniswapV4Adapter` also lets admin attach arbitrary V4 hooks. A malicious or buggy hook is a reentrancy and accounting surface.

---

## Testing — green, too thin for mainnet

What exists is a lifecycle smoke test plus rebalance/write-off happy paths. Tests pass because they use 1:1 mock rates and `minOut = 0`.

Coverage (forge coverage, `--ir-minimum`):

| File | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `src/Pricing.sol` | 100% | 100% | 60% | 100% |
| `src/Swap_mod.sol` | 100% | 83% | 20% | 100% |
| `src/Vault.sol` | 90% | 82% | **26%** | 82% |
| `src/ZenoIndexVault.sol` | 62% | 55% | **0%** | 50% |
| `src/adapters/UniswapV4Adapter.sol` | 85% | 86% | 29% | 71% |
| `src/libraries/VaultMath.sol` | 75% | 61% | **6%** | 78% |
| **Total** | **79%** | **72%** | **21%** | **78%** |

Missing, and needed before mainnet:

- Path injection on `swapUsdcToAsset` / `executeRebalance` (wrong output token, `minOut = 0` sandwich).
- Rebalance buying while `totalPendingUsdc` or `vaultRedeemEscrowTotal` is non-zero.
- Duplicate `assetIds`, unregistered ids in `setTargetAllocations`.
- Fee-bound enforcement (the constants are dead).
- Pause / emergency / `adminLocked` matrix.
- Concurrent redemptions, write-off during redeem, redeem with a retired slot.
- Share-cap clamp vs `previewDeposit`.
- Reentrancy via a V4 hook or ERC777-style token.
- Oracle: stale, zero, huge, decimal mismatch.
- Donation / inflation around genesis.
- Fee-on-transfer and rebasing assets (accounting assumes 1:1 receipt).
- Fuzz tests on `VaultMath` (carve overflow loop, share mint rounding) and invariants: `totalPendingUsdc == sum(_usdcTargetAmount)`, `vaultRedeemEscrowTotal == sum(redeemUsdcBal)`, NAV never counts reserved or escrow twice.

`ZenoIndexVault` admin surface is half untested: two-step super-admin, treasury, emergency, creation gate, `setAssetActive`, `setVaultEmergencyLock`, `setOperator`.

---

## Operational blockers

1. Do not run `script/Deploy.s.sol` on mainnet. Write a production script that takes existing USDC, a production oracle (TWAP or push oracle with heartbeat), and `UniswapV4Adapter` with an admin that is not the hot deployer key.
2. Treat manager + `isOperator` + superAdmin as full custody of every vault until rebalance paths and operator scope are constrained.
3. Get an independent audit. Index vaults that hold user assets and call AMMs are a standard audit target.
4. Pin compiler and oracle addresses in the deploy runbook. `foundry.toml` has no `solc` pin; `priceOracle` is immutable after construct.

---

## Suggested order of work

1. Lock `swapUsdcToAsset` / `executeRebalance` paths and oracle-based slippage; stop rebalance from spending escrow/pending.
2. Enforce fee bounds; require `etfCreationAuthority`; reject duplicate asset ids.
3. Add `nonReentrant`; zero token allowances after each swap; use `SafeERC20`.
4. Make write-off / slot retirement redeem-safe; add a cancel or timeout for stuck redeems.
5. Replace mocks in the deploy path; add a real oracle with staleness checks.
6. Add the adversarial tests above, plus invariants, and get a third-party audit.
