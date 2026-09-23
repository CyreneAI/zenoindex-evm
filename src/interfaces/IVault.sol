// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Surface ZenoIndexVault.sol uses to call into a Vault.sol clone: post-clone init, and the
///         super-admin-gated relay for Path B write-off/reactivate confirmation.
interface IVault {
    function init(
        uint64 vaultId,
        address manager_,
        address feeRecipient_,
        uint16 depositFeeBps_,
        uint16 redeemFeeBps_,
        uint64[] calldata assetIds,
        uint16[] calldata allocationBps,
        uint8 fundType,
        uint256 maxShares_,
        string calldata name_,
        string calldata symbol_
    ) external;

    /// @dev Callable only by ZenoIndexVault.sol (`msg.sender == zenoIndexVault`), which itself enforces
    ///      `onlySuperAdmin` before relaying here.
    function executeWriteOff(uint64 assetId) external;

    /// @dev Same caller restriction as executeWriteOff.
    function executeReactivate(uint64 assetId) external;

    /// @dev Same caller restriction as executeWriteOff. Moves a written-off asset's balance to `to`.
    function executeSweep(uint64 assetId, address to) external;
}
