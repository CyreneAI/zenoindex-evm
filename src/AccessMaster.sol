// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessMaster} from "./interfaces/IAccessMaster.sol";

/// @notice Singleton role + treasury registry — the sole source of truth for who is admin,
///         who is an operator, and where fees go, for the whole protocol.
///
///         Role management is OpenZeppelin AccessControl itself, not a hand-rolled
///         reimplementation: ADMIN_ROLE is DEFAULT_ADMIN_ROLE, transferred in one call by
///         the current super-admin via `setSuperAdmin` (grants the role to the new admin and
///         revokes it from the caller atomically — no separate acceptance step, no delay).
///         OPERATOR_ROLE is granted/revoked via `addOperator` / `removeOperator`
///         (admin-only, thin wrappers over OZ's own `_grantRole` / `_revokeRole` — OZ's
///         public `grantRole` / `revokeRole` remain usable too, since these don't disable
///         them, just give the role its own named entry points). `superAdmin()` /
///         `isOperator()` / `treasury()` below are read-only aliases over that state for the
///         vocabulary ZenoIndexVault.sol and Vault.sol already read live via IAccessMaster.
contract AccessMaster is AccessControl, IAccessMaster {
    // ── Constants ─────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ── State ─────────────────────────────────────────────────────────────────
    address public treasury;

    /// @dev Plain AccessControl has no built-in "who holds this role" enumeration, so the
    ///      single ADMIN_ROLE holder is tracked explicitly here — kept in sync by the
    ///      constructor and `setSuperAdmin`, the only two places ADMIN_ROLE is ever granted.
    address private _superAdmin;

    // ── Events ────────────────────────────────────────────────────────────────
    event SuperAdminTransferred(address indexed previousSuperAdmin, address indexed newSuperAdmin);
    event OperatorAdded(address indexed account);
    event OperatorRemoved(address indexed account);
    event TreasuryUpdated(address indexed treasury);

    // ── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param initialSuperAdmin The initial ADMIN_ROLE (DEFAULT_ADMIN_ROLE) holder.
    /// @param initialTreasury The initial fee-recipient treasury address.
    constructor(address initialSuperAdmin, address initialTreasury) {
        if (initialSuperAdmin == address(0)) revert ZeroAddress();
        if (initialTreasury == address(0)) revert ZeroAddress();
        _grantRole(ADMIN_ROLE, initialSuperAdmin);
        _superAdmin = initialSuperAdmin;
        treasury = initialTreasury;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Transfers ADMIN_ROLE to `newSuperAdmin` in one call — no pending step, no
    ///         acceptance required from `newSuperAdmin`. Callable only by the current
    ///         super-admin. Irreversible if `newSuperAdmin` is wrong: double-check the
    ///         address before calling.
    function setSuperAdmin(address newSuperAdmin) external onlyRole(ADMIN_ROLE) {
        if (newSuperAdmin == address(0)) revert ZeroAddress();
        address previous = msg.sender;
        _grantRole(ADMIN_ROLE, newSuperAdmin);
        _revokeRole(ADMIN_ROLE, previous);
        _superAdmin = newSuperAdmin;
        emit SuperAdminTransferred(previous, newSuperAdmin);
    }

    /// @notice Grants OPERATOR_ROLE to `account`. Admin-only.
    function addOperator(address account) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(OPERATOR_ROLE, account);
        emit OperatorAdded(account);
    }

    /// @notice Revokes OPERATOR_ROLE from `account`. Admin-only.
    function removeOperator(address account) external onlyRole(ADMIN_ROLE) {
        _revokeRole(OPERATOR_ROLE, account);
        emit OperatorRemoved(account);
    }

    function setTreasury(address treasury_) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Getters
    // ══════════════════════════════════════════════════════════════════════════

    function superAdmin() public view returns (address) {
        return _superAdmin;
    }

    function isOperator(address account) public view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }
}
