Verified as actually fixed (C1–C6 + the mechanical Highs + the NAV-DOS High). Full detail in [`BUGFIX_REPORT.md`](./BUGFIX_REPORT.md).

• swapUsdcToAsset is manager-gated and requires path[last] == mint

• Rebalance buys exclude pending USDC and redeem escrow; path ends are checked

• Production Deploy.s.sol (no mocks)

• Fee bounds and a mandatory creation gate

• Duplicate asset ids / mints rejected

• ReentrancyGuard, post-swap approve(0), oracle zero-address + setPriceOracle

• C6, fully fixed (follow-up): the original fix only blocked write-off of the exact reserved slot. A vault-wide `activeRedeemCount` counter now blocks slot retirement — via write-off OR executeRebalance's auto-retire — whenever ANY redeem is active, not just one reserved on the retiring slot itself. `_retireSlot` asserts the invariant directly so a future caller can't reintroduce the gap.

• setTargetAllocations now rejects unregistered/inactive asset ids (was: NAV DOS — an unregistered id resolves to mint == address(0), and every subsequent NAV read reverts, bricking the vault).

Still open, now listed as High in the report (unchanged from before this pass):

• Global isOperator + caller-supplied minOut / intermediate hops

• No oracle freshness and no production oracle in this repo

• Pause/emergency still only block deposits / createVault

• No redeem cancel

• Wind-down against a live AMM leaves dust and never retires the slot in one pass (documented behavior, not a correctness bug — the drift band correctly no-ops on dust below threshold; see test_ExecuteRebalance_WindDownSellsDownToSubDriftBandDust)

• Unswept written-off tokens, arbitrary V4 hooks

An independent audit is still recommended before mainnet — a green test suite proved insufficient once already (see BUGFIX_REPORT.md's note on C6's incomplete first fix).
