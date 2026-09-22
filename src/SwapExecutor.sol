// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Singleton swap-execution module, called cross-contract by every Vault.sol clone.
///         Holds exactly one piece of state: the currently-registered ISwapRouter/DEX-adapter
///         address, settable only by ZenoIndexVault.sol (which gates the call with onlySuperAdmin).
contract SwapExecutor {
    // ── State ─────────────────────────────────────────────────────────────────
    address public zenoIndexVault;
    address public router;

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyZenoIndexVault() {
        if (msg.sender != zenoIndexVault) revert OnlyZenoIndexVault();
        _;
    }

    // ── Events ────────────────────────────────────────────────────────────────
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    // ── Errors ────────────────────────────────────────────────────────────────
    error OnlyZenoIndexVault();
    error ZeroAddress();

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address zenoIndexVault_) {
        if (zenoIndexVault_ == address(0)) revert ZeroAddress();
        zenoIndexVault = zenoIndexVault_;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Callable only by ZenoIndexVault.sol, which itself enforces `onlySuperAdmin` before
    ///      calling here — mirrors the Path B write-off relay pattern.
    function setRouter(address newRouter) external onlyZenoIndexVault {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(router, newRouter);
        router = newRouter;
    }

    /// @notice Executes a swap along `path` through the currently-registered router.
    /// @dev `from` (the calling Vault.sol clone) must have approved `router` directly —
    ///      SwapExecutor never custodies the tokens, it only orchestrates the call.
    function executeSwap(address[] calldata path, uint256 amountIn, uint256 minAmountOut, address from, address to)
        external
        returns (uint256 amountOut)
    {
        address r = router;
        require(r != address(0), "NO_ROUTER");
        amountOut = ISwapRouter(r).swap(path, amountIn, minAmountOut, from, to);
    }
}
