// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "./Vault.sol";
import {IZenoIndexVault} from "./interfaces/IZenoIndexVault.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IAccessMaster} from "./interfaces/IAccessMaster.sol";
import {Constants} from "./libraries/Constants.sol";

interface ISwapModAdmin {
    function setRouter(address newRouter) external;
}

/// @notice Root contract: emergency flag, asset registry, the NavCalculation/SwapExecutor
///         address registry, and the ERC-1167 clone factory for vaults. Super-admin,
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
    address public pricingModule;
    address public swapModule;

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
    event PricingModuleSet(address indexed module);
    event SwapModuleSet(address indexed module, address indexed router);
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

    function setPricingModule(address module) external onlySuperAdmin {
        if (module == address(0)) revert ZeroAddress();
        pricingModule = module;
        emit PricingModuleSet(module);
    }

    /// @notice Sets SwapExecutor.sol itself (rare) — for switching the DEX-execution router
    ///         address that clones use day to day, use `setSwapRouter` instead.
    function setSwapModule(address module) external onlySuperAdmin {
        if (module == address(0)) revert ZeroAddress();
        swapModule = module;
        emit SwapModuleSet(module, address(0));
    }

    /// @notice Relays to SwapExecutor.sol's `setRouter`, which is itself gated to only accept
    ///         calls from this contract.
    function setSwapRouter(address router) external onlySuperAdmin {
        if (router == address(0)) revert ZeroAddress();
        ISwapModAdmin(swapModule).setRouter(router);
        emit SwapModuleSet(swapModule, router);
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
}
