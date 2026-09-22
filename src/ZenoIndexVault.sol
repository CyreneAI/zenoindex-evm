// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "./Vault.sol";
import {IZenoIndexVault} from "./interfaces/IZenoIndexVault.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IAccessMaster} from "./interfaces/IAccessMaster.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {ERC20Minimal} from "./tokens/ERC20Minimal.sol";
import {Constants} from "./libraries/Constants.sol";

/// @notice Root contract: emergency flag, asset registry, NAV/valuation (formerly
///         NavCalculation.sol), swap execution (formerly SwapExecutor.sol), and the
///         ERC-1167 clone factory for vaults — all in one module now, so every Vault.sol
///         clone has exactly one external address to call back into. Super-admin,
///         operator roles, and treasury are NOT stored here — they live in AccessMaster.sol
///         (set once at construction) and are read live via IAccessMaster, so there is
///         exactly one place across the whole protocol that answers "who is admin /
///         operator" and "where do fees go".
///         No `init_global_state` — a real constructor does that job.

contract ZenoIndexVault is IZenoIndexVault {
    // ── Structs ───────────────────────────────────────────────────────────────
    struct CreateVaultParams {
        address feeRecipient; // address(0) -> msg.sender
        uint16 depositFeeBps;
        uint16 redeemFeeBps;
        uint64[] assetIds;
        uint16[] allocationBps;
        uint8 fundType; // 0 = Fixed, 1 = Dynamic
        uint256 maxShares;
        string name;
        string symbol;
    }

    struct AssetInfo {
        uint64 assetId;
        address mint;
        bool active;
        bool exists;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────
    address public accessMaster;
    address public usdcToken;
    bool public isEmergency;

    // ── Singleton registry ────────────────────────────────────────────────────
    address public vaultImplementation;

    // ── NAV / valuation (formerly NavCalculation.sol) ────────────────────────────
    /// @dev priceUsdcPerUnit helpers: usdcValue = amount * priceNum / priceDen
    mapping(address => uint256) public priceNum; // USDC out (6 dec)
    mapping(address => uint256) public priceDen; // token in (raw units)

    // ── Swap execution (formerly SwapExecutor.sol) ───────────────────────────────
    address public router;

    // ── Asset registry ────────────────────────────────────────────────────────
    uint64 public totalAssets;
    mapping(uint64 => AssetInfo) internal _assets;
    mapping(address => bool) internal _mintRegistered;

    // ── Vault (clone) registry ────────────────────────────────────────────────
    uint64 public totalVaults;
    mapping(uint64 => address) public vaultClones;

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlySuperAdmin() {
        if (msg.sender != IAccessMaster(accessMaster).superAdmin())
            revert NotSuperAdmin();
        _;
    }

    /// @dev Super-admin or any account flagged as an operator on AccessMaster — used for
    ///      asset-registry actions (createAsset / setAssetActive) so operators can add/remove
    ///      assets without needing super-admin's other, more sensitive powers (treasury,
    ///      emergency, module rotation, super-admin transfer).
    modifier onlySuperAdminOrOperator() {
        IAccessMaster roles = IAccessMaster(accessMaster);
        if (msg.sender != roles.superAdmin() && !roles.isOperator(msg.sender))
            revert NotSuperAdmin();
        _;
    }

    // ── Events ────────────────────────────────────────────────────────────────
    event EmergencySet(bool isEmergency);
    event UsdcTokenSet(address indexed oldUsdcToken, address indexed newUsdcToken);
    event PriceSet(address indexed token, uint256 usdcOut, uint256 tokenIn);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event AssetCreated(uint64 indexed assetId, address mint);
    event AssetActiveSet(uint64 indexed assetId, bool active);
    event VaultCreated(
        uint64 indexed vaultId,
        address indexed clone,
        address manager
    );
    event WriteOffConfirmed(uint64 indexed vaultId, uint64 indexed assetId);
    event ReactivateConfirmed(uint64 indexed vaultId, uint64 indexed assetId);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotSuperAdmin();
    error ZeroAddress();
    error AlreadyExists();
    error AssetMissing();
    error AssetInactive();
    error NoAssets();
    error TooManyAssets();
    error InvalidAllocation();
    error VaultNotFound();
    error DuplicateMint();
    error NoPrice();
    error NoRouter();

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address usdcToken_, address vaultImplementation_, address accessMaster_) {
        if (usdcToken_ == address(0) || vaultImplementation_ == address(0) || accessMaster_ == address(0)) {
            revert ZeroAddress();
        }
        accessMaster = accessMaster_;
        usdcToken = usdcToken_;
        vaultImplementation = vaultImplementation_;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters — admin config
    // ══════════════════════════════════════════════════════════════════════════

    function setEmergency(bool isEmergency_) external onlySuperAdmin {
        isEmergency = isEmergency_;
        emit EmergencySet(isEmergency_);
    }

    /// @notice Rotates the deposit stablecoin (USDC/USDG) address.
    /// @dev Every existing vault clone's deposit/redeem/fee accounting and NAV math treats
    ///      `usdcToken` as a fixed 1:1 peg read live from here — changing it after any vault
    ///      has live balances desyncs that accounting (old balances are still in the old
    ///      token). Safe only before `createVault` is ever called, or with full awareness
    ///      of that consequence.
    function setUsdcToken(address newUsdcToken) external onlySuperAdmin {
        if (newUsdcToken == address(0)) revert ZeroAddress();
        emit UsdcTokenSet(usdcToken, newUsdcToken);
        usdcToken = newUsdcToken;
    }

    /// @notice Sets raw price: `usdcOut` USDC (6 dec) for `tokenIn` raw token units.
    function setPrice(address token, uint256 usdcOut, uint256 tokenIn) external onlySuperAdmin {
        if (token == address(0) || tokenIn == 0) revert ZeroAddress();
        priceNum[token] = usdcOut;
        priceDen[token] = tokenIn;
        emit PriceSet(token, usdcOut, tokenIn);
    }

    /// @dev Convenience: USD price for 1 whole token (accounts for decimals).
    ///      e.g. token 6 dec at $2 → setPriceWhole(token, 2_000_000)
    function setPriceWhole(address token, uint256 usdcPerWholeToken) external onlySuperAdmin {
        if (token == address(0)) revert ZeroAddress();
        uint8 dec = ERC20Minimal(token).decimals();
        priceNum[token] = usdcPerWholeToken;
        priceDen[token] = 10 ** uint256(dec);
        emit PriceSet(token, usdcPerWholeToken, 10 ** uint256(dec));
    }

    /// @notice Sets the DEX-execution router address that clones swap through day to day.
    function setSwapRouter(address newRouter) external onlySuperAdmin {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(router, newRouter);
        router = newRouter;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters — asset registry
    // ══════════════════════════════════════════════════════════════════════════

    function createAsset(
        address mint
    ) external onlySuperAdminOrOperator returns (uint64 assetId) {
        if (mint == address(0)) revert ZeroAddress();
        if (_mintRegistered[mint]) revert DuplicateMint();
        assetId = totalAssets;
        _assets[assetId] = AssetInfo({
            assetId: assetId,
            mint: mint,
            active: true,
            exists: true
        });
        _mintRegistered[mint] = true;
        totalAssets = assetId + 1;
        emit AssetCreated(assetId, mint);
    }

    /// @notice Toggles an asset's active flag — `active = false` is "remove" (assets are
    ///         never deleted, only deactivated, since existing vaults may still hold slots
    ///         referencing this assetId).
    function setAssetActive(
        uint64 assetId,
        bool active
    ) external onlySuperAdminOrOperator {
        if (!_assets[assetId].exists) revert AssetMissing();
        _assets[assetId].active = active;
        emit AssetActiveSet(assetId, active);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters — ETF factory
    // ══════════════════════════════════════════════════════════════════════════

    function createVault(
        CreateVaultParams calldata params
    ) external returns (uint64 vaultId) {
        if (isEmergency) revert("EMERGENCY");

        uint256 n = params.assetIds.length;
        if (n == 0) revert NoAssets();
        if (n > Constants.MAX_ASSETS) revert TooManyAssets();

        for (uint256 i = 0; i < n; i++) {
            AssetInfo storage a = _assets[params.assetIds[i]];
            if (!a.exists) revert AssetMissing();
            if (!a.active) revert AssetInactive();
            for (uint256 j = i + 1; j < n; j++) {
                if (params.assetIds[j] == params.assetIds[i])
                    revert AlreadyExists();
            }
        }

        vaultId = totalVaults;
        address clone = Clones.clone(vaultImplementation);
        vaultClones[vaultId] = clone;
        totalVaults = vaultId + 1;

        IVault(clone).init(
            vaultId,
            msg.sender,
            params.feeRecipient == address(0)
                ? msg.sender
                : params.feeRecipient,
            params.depositFeeBps,
            params.redeemFeeBps,
            params.assetIds,
            params.allocationBps,
            params.fundType,
            params.maxShares,
            params.name,
            params.symbol
        );

        emit VaultCreated(vaultId, clone, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters — Path B relay + emergency-lock relay
    // ══════════════════════════════════════════════════════════════════════════

    function confirmWriteOff(
        uint64 vaultId,
        uint64 assetId
    ) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        IVault(clone).executeWriteOff(assetId);
        emit WriteOffConfirmed(vaultId, assetId);
    }

    function confirmReactivate(
        uint64 vaultId,
        uint64 assetId
    ) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        IVault(clone).executeReactivate(assetId);
        emit ReactivateConfirmed(vaultId, assetId);
    }

    function setVaultEmergencyLock(
        uint64 vaultId,
        bool locked
    ) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        Vault(clone).setVaultEmergencyLock(locked);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public — swap execution (formerly SwapExecutor.sol)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Executes a swap along `path` through the currently-registered router.
    /// @dev `from` (the calling Vault.sol clone) must have approved `router` directly —
    ///      this contract never custodies the tokens, it only orchestrates the call.
    function executeSwap(address[] calldata path, uint256 amountIn, uint256 minAmountOut, address from, address to)
        external
        returns (uint256 amountOut)
    {
        address r = router;
        if (r == address(0)) revert NoRouter();
        amountOut = ISwapRouter(r).swap(path, amountIn, minAmountOut, from, to);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Getters — roles + treasury, read live from AccessMaster.sol, never cached
    // (IZenoIndexVault surface)
    // ══════════════════════════════════════════════════════════════════════════

    function superAdmin() external view returns (address) {
        return IAccessMaster(accessMaster).superAdmin();
    }

    function isOperator(address account) external view returns (bool) {
        return IAccessMaster(accessMaster).isOperator(account);
    }

    function treasury() external view returns (address) {
        return IAccessMaster(accessMaster).treasury();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Getters — asset registry
    // ══════════════════════════════════════════════════════════════════════════

    function getAsset(
        uint64 assetId
    ) external view returns (uint64, address, bool, bool) {
        AssetInfo storage a = _assets[assetId];
        return (a.assetId, a.mint, a.active, a.exists);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Getters — NAV / valuation (formerly NavCalculation.sol)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Values `amount` of `token` in USDC 6-decimal units.
    ///         USDC/USDG (the factory deposit token) is always 1:1; other tokens use the
    ///         price table maintained on this contract.
    function valueUsdc(address token, uint256 amount) external view returns (uint256) {
        if (token == usdcToken) return amount;
        return _quote(token, amount);
    }

    /// @notice Sums the USD (USDC 6-decimal) value of `vaultClone`'s free (non-reserved)
    ///         balances across `assetIds`.
    /// @param vaultClone The Vault clone whose balances are valued
    /// @param assetIds Current asset slot ids (active + winding-down; never written-off)
    /// @param reservedAmounts Per-asset reserved amounts, same order as `assetIds`
    /// @param excludeFromUsdcLeg Amount to subtract from the raw USDC balance before valuing
    function sumNav(
        address vaultClone,
        uint64[] calldata assetIds,
        uint256[] calldata reservedAmounts,
        uint256 excludeFromUsdcLeg
    ) external view returns (uint256 total) {
        address usdc = usdcToken;
        uint256 n = assetIds.length;
        require(reservedAmounts.length == n, "LEN");

        for (uint256 i = 0; i < n; i++) {
            address mint = _assets[assetIds[i]].mint;
            uint256 bal = ERC20Minimal(mint).balanceOf(vaultClone);
            uint256 free = bal > reservedAmounts[i] ? bal - reservedAmounts[i] : 0;

            if (mint == usdc) {
                free = free > excludeFromUsdcLeg ? free - excludeFromUsdcLeg : 0;
                total += free; // $1 peg
            } else {
                if (free == 0) continue;
                total += _quote(mint, free);
            }
        }
    }

    function _quote(address token, uint256 amount) internal view returns (uint256) {
        uint256 den = priceDen[token];
        if (den == 0) revert NoPrice();
        return (amount * priceNum[token]) / den;
    }
}
