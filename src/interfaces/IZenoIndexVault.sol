// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Read/call surface a Vault.sol clone uses to reach back into ZenoIndexVault.sol.
///         Every field is read live, every call — never cached by the clone.
interface IZenoIndexVault {
    function superAdmin() external view returns (address);
    function treasury() external view returns (address);
    function usdcToken() external view returns (address);
    function isEmergency() external view returns (bool);
    function pricingModule() external view returns (address);
    function swapModule() external view returns (address);
    function isOperator(address account) external view returns (bool);

    /// @return assetId_ The asset's id
    /// @return mint The asset's ERC-20 address
    /// @return active Whether it may be used in new vaults / new allocations
    /// @return exists Whether this assetId has been registered at all
    function getAsset(uint64 assetId) external view returns (uint64 assetId_, address mint, bool active, bool exists);
}
