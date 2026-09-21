// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IZenoIndexVault} from "./interfaces/IZenoIndexVault.sol";
import {ERC20Minimal} from "./tokens/ERC20Minimal.sol";

/// @notice Singleton NAV/valuation module, called cross-contract by every Vault.sol clone.
///         Holds no per-vault storage — every input is passed in or read live from the
///         clone/ZenoIndexVault at call time.
contract Pricing {
    error NoPrice();

    /// @notice Sums the USD (USDC 6-decimal) value of `vaultClone`'s free (non-reserved)
    ///         balances across `assetIds`, using the price oracle registered on `zenoIndexVaultAddr`.
    /// @param zenoIndexVaultAddr The ZenoIndexVault.sol root contract (for asset registry + usdcToken lookup)
    /// @param priceOracle The IPriceOracle to quote non-USDC assets against
    /// @param vaultClone The Vault.sol clone whose balances are being valued
    /// @param assetIds The clone's current asset slot ids (active + winding-down; never
    ///        written-off ids — those are excluded from NAV entirely per the write-off design)
    /// @param reservedAmounts Per-asset amount already reserved for pending redemptions,
    ///        same length/order as `assetIds` — subtracted from the raw balance before valuing
    /// @param excludeFromUsdcLeg Amount to subtract from the raw USDC balance before valuing
    ///        it 1:1 (the caller's undeployed totalPendingUsdc) — everything else about the
    ///        USDC slot is handled the same as any other asset
    function sumNav(
        address zenoIndexVaultAddr,
        address priceOracle,
        address vaultClone,
        uint64[] calldata assetIds,
        uint256[] calldata reservedAmounts,
        uint256 excludeFromUsdcLeg
    ) external view returns (uint256 total) {
        address usdc = IZenoIndexVault(zenoIndexVaultAddr).usdcToken();
        uint256 n = assetIds.length;
        require(reservedAmounts.length == n, "LEN");

        for (uint256 i = 0; i < n; i++) {
            (, address mint,,) = IZenoIndexVault(zenoIndexVaultAddr).getAsset(assetIds[i]);
            uint256 bal = ERC20Minimal(mint).balanceOf(vaultClone);
            uint256 free = bal > reservedAmounts[i] ? bal - reservedAmounts[i] : 0;

            if (mint == usdc) {
                free = free > excludeFromUsdcLeg ? free - excludeFromUsdcLeg : 0;
                total += free; // $1 peg
            } else {
                if (free == 0) continue;
                total += IPriceOracle(priceOracle).quoteUsdc(mint, free);
            }
        }
    }
}
