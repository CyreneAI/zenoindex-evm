// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Read/call surface a Vault.sol clone uses to reach back into ZenoIndexVault.sol.
///         Every field is read live, every call — never cached by the clone. NAV/valuation
///         (formerly NavCalculation.sol) and swap execution (formerly SwapExecutor.sol) are
///         both part of this same surface now — ZenoIndexVault.sol is the one module clones
///         call back into.
interface IZenoIndexVault {
    function superAdmin() external view returns (address);
    function treasury() external view returns (address);
    function usdcToken() external view returns (address);
    function isEmergency() external view returns (bool);
    function router() external view returns (address);
    function isOperator(address account) external view returns (bool);

    /// @return assetId_ The asset's id
    /// @return mint The asset's ERC-20 address
    /// @return active Whether it may be used in new vaults / new allocations
    /// @return exists Whether this assetId has been registered at all
    function getAsset(uint64 assetId) external view returns (uint64 assetId_, address mint, bool active, bool exists);

    /// @notice Values `amount` of `token` in USDC 6-decimal units.
    function valueUsdc(address token, uint256 amount) external view returns (uint256);

    /// @notice Sums the USD (USDC 6-decimal) value of `vaultClone`'s free (non-reserved)
    ///         balances across `assetIds`.
    function sumNav(
        address vaultClone,
        uint64[] calldata assetIds,
        uint256[] calldata reservedAmounts,
        uint256 excludeFromUsdcLeg
    ) external view returns (uint256);

    /// @notice Executes a swap along `path` through the currently-registered router.
    function executeSwap(address[] calldata path, uint256 amountIn, uint256 minAmountOut, address from, address to)
        external
        returns (uint256 amountOut);
}
