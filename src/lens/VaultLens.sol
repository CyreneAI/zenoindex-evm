// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Constants} from "../libraries/Constants.sol";

/// @dev The Vault getters the lens reads. Every one also exists on the deployed mainnet
///      implementation (commit 7663cc6), so the lens works against live clones.
interface ILensVault {
    function zenoIndexVault() external view returns (address);
    function numAssets() external view returns (uint8);
    function assetIdAt(uint8 index) external view returns (uint64);
    function allocationBpsAt(uint8 index) external view returns (uint16);
    function usdcTargetAmountAt(uint8 index) external view returns (uint256);
    function reservedAt(uint8 index) external view returns (uint256);
    function totalPendingUsdc() external view returns (uint256);
    function vaultRedeemEscrowTotal() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function isWrittenOff(uint64 assetId) external view returns (bool);
}

/// @dev The factory getters the lens reads. `hasPrice` is deliberately not used: the
///      deployed factory's version ignores staleness, so the lens checks age itself.
interface ILensFactory {
    function usdcToken() external view returns (address);
    function totalAssets() external view returns (uint64);
    function getAsset(uint64 assetId) external view returns (uint64, address, bool, bool);
    function priceNum(address token) external view returns (uint256);
    function priceDen(address token) external view returns (uint256);
    function priceUpdatedAt(address token) external view returns (uint256);
    function maxPriceAge() external view returns (uint256);
}

/// @notice Read-only NAV / AUM / per-asset allocation view over Vault clones. Holds no
///         state and needs no role, so it works for already-deployed vaults and can be
///         run as a deployless `eth_call`.
/// @dev Mirrors `ZenoIndexVault.sumNav` + `Vault.totalNav` exactly, except that a missing
///      or stale price never reverts: the asset is valued at its last stored price (0 if
///      none) and `navComplete` is false. Whenever `navComplete` is true,
///      `totalNavUsdc == Vault.totalNav()`.
contract VaultLens {
    enum PriceStatus {
        Peg, // the stablecoin itself, valued 1:1
        Fresh,
        Stale, // older than maxPriceAge — Vault.totalNav() reverts if the vault holds any
        Missing // never priced — Vault.totalNav() reverts if the vault holds any
    }

    struct AssetView {
        uint8 slot; // shifts when another slot retires — key rows on assetId
        uint64 assetId;
        address mint;
        uint16 targetBps;
        uint16 currentBps; // valueUsdc / totalNavUsdc
        uint256 balance; // raw token balance held by the vault
        uint256 reserved; // owed to in-flight redeemers; not in NAV
        uint256 freeAmount; // the part counted in NAV
        uint256 valueUsdc; // freeAmount in USDC (6 dec)
        uint256 reservedValueUsdc;
        uint256 pendingUsdc; // undeployed USDC earmarked to buy this asset
        PriceStatus priceStatus;
        uint256 priceNum; // value = amount * priceNum / priceDen
        uint256 priceDen;
        uint256 priceUpdatedAt;
    }

    /// @dev Written-off assets have no slot and are excluded from NAV, but their tokens
    ///      stay in the vault until swept.
    struct WrittenOffView {
        uint64 assetId;
        address mint;
        uint256 balance;
        uint256 valueUsdc;
        PriceStatus priceStatus;
    }

    struct VaultView {
        address vault;
        address factory;
        address usdc;
        // ── NAV: what current shareholders own ──
        uint256 totalNavUsdc; // assetsNavUsdc + pendingUsdc
        bool navComplete; // false if a held asset's price is stale or missing
        uint256 assetsNavUsdc; // == Vault._sumNav(): slot values + unallocatedUsdc
        uint256 pendingUsdc; // deposited USDC not yet swapped into its target assets
        uint256 unallocatedUsdc; // free USDC held while USDC is not a slot
        uint16 pendingBps;
        uint16 unallocatedBps;
        // ── Owed to redeemers who already burned their shares; not in NAV ──
        uint256 redeemEscrowUsdc;
        uint256 reservedValueUsdc;
        // ── AUM: everything the vault manages, including what it still owes redeemers.
        //    Written-off assets are excluded: they are no longer managed, only held until swept.
        uint256 aumUsdc; // totalNavUsdc + redeemEscrowUsdc + reservedValueUsdc
        // ── Shares ──
        uint256 totalShares;
        uint256 navPerShare; // Constants.PRICE_SCALE units, like baselineSharePrice; 0 before genesis
        uint256 maxPriceAge;
        AssetView[] assets;
        WrittenOffView[] writtenOff;
    }

    function getVault(address vault) public view returns (VaultView memory v) {
        ILensVault vlt = ILensVault(vault);
        ILensFactory f = ILensFactory(vlt.zenoIndexVault());
        v.vault = vault;
        v.factory = address(f);
        v.usdc = f.usdcToken();
        v.maxPriceAge = f.maxPriceAge();
        v.pendingUsdc = vlt.totalPendingUsdc();
        v.redeemEscrowUsdc = vlt.vaultRedeemEscrowTotal();
        v.totalShares = vlt.totalShares();
        v.navComplete = true;

        uint8 n = vlt.numAssets();
        v.assets = new AssetView[](n);
        bool hasUsdcSlot;
        for (uint8 i = 0; i < n; i++) {
            AssetView memory a = _slotView(vlt, f, v, i);
            if (a.mint == v.usdc) {
                hasUsdcSlot = true;
            } else if (a.freeAmount > 0 && a.priceStatus != PriceStatus.Fresh) {
                // sumNav only quotes a non-USDC asset with a nonzero free balance.
                v.navComplete = false;
            }
            v.assetsNavUsdc += a.valueUsdc;
            v.reservedValueUsdc += a.reservedValueUsdc;
            v.assets[i] = a;
        }
        // Same as sumNav: free USDC still counts when USDC is not a slot.
        if (!hasUsdcSlot) {
            uint256 bal = IERC20(v.usdc).balanceOf(vault);
            uint256 locked = v.pendingUsdc + v.redeemEscrowUsdc;
            v.unallocatedUsdc = bal > locked ? bal - locked : 0;
            v.assetsNavUsdc += v.unallocatedUsdc;
        }

        v.totalNavUsdc = v.assetsNavUsdc + v.pendingUsdc;
        v.aumUsdc = v.totalNavUsdc + v.redeemEscrowUsdc + v.reservedValueUsdc;
        v.navPerShare = v.totalShares == 0 ? 0 : (v.totalNavUsdc * Constants.PRICE_SCALE) / v.totalShares;

        for (uint8 i = 0; i < n; i++) {
            v.assets[i].currentBps = _bps(v.assets[i].valueUsdc, v.totalNavUsdc);
        }
        v.pendingBps = _bps(v.pendingUsdc, v.totalNavUsdc);
        v.unallocatedBps = _bps(v.unallocatedUsdc, v.totalNavUsdc);

        v.writtenOff = _writtenOff(vlt, f, v);
    }

    function getVaults(address[] calldata vaults) external view returns (VaultView[] memory out) {
        out = new VaultView[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            out[i] = getVault(vaults[i]);
        }
    }

    /// @notice Non-reverting `Vault.totalNav()`.
    function navOf(address vault) external view returns (uint256 totalNavUsdc, bool complete) {
        VaultView memory v = getVault(vault);
        return (v.totalNavUsdc, v.navComplete);
    }

    // ── Internal views ────────────────────────────────────────────────────────

    function _slotView(ILensVault vlt, ILensFactory f, VaultView memory v, uint8 i)
        internal
        view
        returns (AssetView memory a)
    {
        a.slot = i;
        a.assetId = vlt.assetIdAt(i);
        (, a.mint,,) = f.getAsset(a.assetId);
        a.targetBps = vlt.allocationBpsAt(i);
        a.pendingUsdc = vlt.usdcTargetAmountAt(i);
        a.reserved = vlt.reservedAt(i);
        a.balance = IERC20(a.mint).balanceOf(v.vault);

        // Same as Vault._freeBalance: a USDC slot's pending and escrowed cash is not free.
        uint256 locked = a.reserved;
        if (a.mint == v.usdc) locked += v.pendingUsdc + v.redeemEscrowUsdc;
        a.freeAmount = a.balance > locked ? a.balance - locked : 0;

        (a.priceStatus, a.priceNum, a.priceDen, a.priceUpdatedAt) = _price(f, a.mint, v.usdc, v.maxPriceAge);
        a.valueUsdc = _value(a.priceStatus, a.priceNum, a.priceDen, a.freeAmount);
        uint256 reservedHeld = a.reserved < a.balance ? a.reserved : a.balance;
        a.reservedValueUsdc = _value(a.priceStatus, a.priceNum, a.priceDen, reservedHeld);
    }

    /// @dev Scans the whole asset registry — written-off ids are only kept in a mapping.
    function _writtenOff(ILensVault vlt, ILensFactory f, VaultView memory v)
        internal
        view
        returns (WrittenOffView[] memory out)
    {
        uint64 total = f.totalAssets();
        out = new WrittenOffView[](total);
        uint256 count;
        for (uint64 id = 0; id < total; id++) {
            if (!vlt.isWrittenOff(id)) continue;
            WrittenOffView memory w;
            w.assetId = id;
            (, w.mint,,) = f.getAsset(id);
            w.balance = IERC20(w.mint).balanceOf(v.vault);
            (PriceStatus s, uint256 num, uint256 den,) = _price(f, w.mint, v.usdc, v.maxPriceAge);
            w.priceStatus = s;
            w.valueUsdc = _value(s, num, den, w.balance);
            out[count++] = w;
        }
        // Shrink the array to the entries actually filled.
        assembly ("memory-safe") {
            mstore(out, count)
        }
    }

    /// @dev Same staleness rule as ZenoIndexVault._checkFresh; maxAge 0 disables it.
    function _price(ILensFactory f, address mint, address usdc, uint256 maxAge)
        internal
        view
        returns (PriceStatus status, uint256 num, uint256 den, uint256 updatedAt)
    {
        if (mint == usdc) return (PriceStatus.Peg, 1, 1, 0);
        num = f.priceNum(mint);
        den = f.priceDen(mint);
        updatedAt = f.priceUpdatedAt(mint);
        if (den == 0) status = PriceStatus.Missing;
        else if (maxAge != 0 && block.timestamp > updatedAt + maxAge) status = PriceStatus.Stale;
        else status = PriceStatus.Fresh;
    }

    /// @dev Same rounding as ZenoIndexVault._quote, so per-asset values sum to sumNav exactly.
    function _value(PriceStatus status, uint256 num, uint256 den, uint256 amount) internal pure returns (uint256) {
        if (status == PriceStatus.Peg) return amount;
        if (status == PriceStatus.Missing || amount == 0) return 0;
        return (amount * num) / den;
    }

    function _bps(uint256 part, uint256 whole) internal pure returns (uint16) {
        if (whole == 0) return 0;
        return uint16((part * Constants.BPS_DENOM) / whole);
    }
}
