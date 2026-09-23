// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessMaster} from "./interfaces/IAccessMaster.sol";

/// @notice Singleton role + treasury registry — the sole source of truth for who is admin,
///         who is an operator, and where fees go, for the whole protocol.
///
///         Role management is OpenZeppelin AccessControl itself, not a hand-rolled
///         reimplementation: ADMIN_ROLE is DEFAULT_ADMIN_ROLE and has exactly one holder,
///         always equal to `superAdmin()`. It moves only through the two-step
///         `setSuperAdmin` (propose) → `acceptSuperAdmin` (new admin accepts) flow — OZ's
///         public `grantRole` / `revokeRole` / `renounceRole` revert for ADMIN_ROLE so the
///         role and `_superAdmin` can never drift apart.
///         OPERATOR_ROLE is granted/revoked via `addOperator` / `removeOperator`
///         (admin-only, thin wrappers over OZ's own `_grantRole` / `_revokeRole` — OZ's
///         public `grantRole` / `revokeRole` remain usable for it too). `superAdmin()` /
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
    ///      constructor and `acceptSuperAdmin`, the only two places ADMIN_ROLE is ever granted.
    address private _superAdmin;

    /// @notice Address proposed by `setSuperAdmin`, waiting to call `acceptSuperAdmin`.
    address public pendingSuperAdmin;

    // ── Events ────────────────────────────────────────────────────────────────
    event SuperAdminTransferStarted(address indexed currentSuperAdmin, address indexed pendingSuperAdmin);
    event SuperAdminTransferred(address indexed previousSuperAdmin, address indexed newSuperAdmin);
    event OperatorAdded(address indexed account);
    event OperatorRemoved(address indexed account);
    event TreasuryUpdated(address indexed treasury);

    // ── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error NotPendingSuperAdmin();
    error AdminRoleManagedBySetSuperAdmin();

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

    /// @notice Step 1 of the super-admin transfer: proposes `newSuperAdmin`. Nothing moves
    ///         until `newSuperAdmin` calls `acceptSuperAdmin`, so a typo is recoverable —
    ///         just propose again (a new proposal overwrites the old one).
    function setSuperAdmin(address newSuperAdmin) external onlyRole(ADMIN_ROLE) {
        if (newSuperAdmin == address(0)) revert ZeroAddress();
        pendingSuperAdmin = newSuperAdmin;
        emit SuperAdminTransferStarted(msg.sender, newSuperAdmin);
    }

    /// @notice Step 2: the proposed address accepts, taking ADMIN_ROLE from the current
    ///         super-admin atomically.
    function acceptSuperAdmin() external {
        if (msg.sender != pendingSuperAdmin) revert NotPendingSuperAdmin();
        address previous = _superAdmin;
        delete pendingSuperAdmin;
        _revokeRole(ADMIN_ROLE, previous);
        _grantRole(ADMIN_ROLE, msg.sender);
        _superAdmin = msg.sender;
        emit SuperAdminTransferred(previous, msg.sender);
    }

    /// @dev ADMIN_ROLE moves only via setSuperAdmin/acceptSuperAdmin.
    function grantRole(bytes32 role, address account) public override {
        if (role == ADMIN_ROLE) revert AdminRoleManagedBySetSuperAdmin();
        super.grantRole(role, account);
    }

    /// @dev ADMIN_ROLE moves only via setSuperAdmin/acceptSuperAdmin.
    function revokeRole(bytes32 role, address account) public override {
        if (role == ADMIN_ROLE) revert AdminRoleManagedBySetSuperAdmin();
        super.revokeRole(role, account);
    }

    /// @dev ADMIN_ROLE moves only via setSuperAdmin/acceptSuperAdmin.
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == ADMIN_ROLE) revert AdminRoleManagedBySetSuperAdmin();
        super.renounceRole(role, callerConfirmation);
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
