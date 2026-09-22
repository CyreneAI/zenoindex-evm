// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "./Vault.sol";
import {IZenoIndexVault} from "./interfaces/IZenoIndexVault.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Constants} from "./libraries/Constants.sol";

interface ISwapModAdmin {
    function setRouter(address newRouter) external;
}

/// @notice Root contract: super-admin, treasury, emergency flag, asset registry, the
///         NavCalculation/SwapExecutor address registry, and the ERC-1167 clone factory for vaults.
///         No `init_global_state` — a real constructor does that job.
contract ZenoIndexVault is IZenoIndexVault {
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
    address public superAdmin;
    address public pendingSuperAdminAddr;
    address public treasury;
    address public usdcToken;
    address public priceOracle;
    bool public isEmergency;
    address public etfCreationAuthority;

    // ── Singleton registry ────────────────────────────────────────────────────
    address public vaultImplementation;
    address public pricingModule;
    address public swapModule;

    // ── Roles ─────────────────────────────────────────────────────────────────
    mapping(address => bool) public isOperator;

    // ── Asset registry ────────────────────────────────────────────────────────
    mapping(uint64 => AssetInfo) internal _assets;
    uint64 public totalAssets;
    mapping(address => bool) internal _mintRegistered;

    // ── Vault (clone) registry ────────────────────────────────────────────────
    uint64 public totalVaults;
    mapping(uint64 => address) public vaultClones;

    // ── Events ────────────────────────────────────────────────────────────────
    event SuperAdminProposed(address indexed newSuperAdmin);
    event SuperAdminAccepted(address indexed newSuperAdmin);
    event TreasuryUpdated(address indexed treasury);
    event EmergencySet(bool isEmergency);
    event EtfCreationAuthoritySet(address indexed authority);
    event PricingModuleSet(address indexed module);
    event SwapModuleSet(address indexed module, address indexed router);
    event OperatorSet(address indexed account, bool isOperator);
    event AssetCreated(uint64 indexed assetId, address mint);
    event AssetActiveSet(uint64 indexed assetId, bool active);
    event VaultCreated(uint64 indexed vaultId, address indexed clone, address manager);
    event WriteOffConfirmed(uint64 indexed vaultId, uint64 indexed assetId);
    event ReactivateConfirmed(uint64 indexed vaultId, uint64 indexed assetId);
    event PriceOracleSet(address indexed oracle);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotSuperAdmin();
    error NotPendingSuperAdmin();
    error ZeroAddress();
    error AlreadyExists();
    error AssetMissing();
    error AssetInactive();
    error NoAssets();
    error TooManyAssets();
    error InvalidAllocation();
    error UnauthorizedGateAuthority();
    error VaultNotFound();
    error CreationGateNotSet();
    error DuplicateMint();

    modifier onlySuperAdmin() {
        if (msg.sender != superAdmin) revert NotSuperAdmin();
        _;
    }

    /// @dev Super-admin or any account flagged via setOperator — used for asset-registry
    ///      actions (createAsset / setAssetActive) so operators can add/remove assets
    ///      without needing super-admin's other, more sensitive powers (treasury, emergency,
    ///      module/oracle rotation, super-admin transfer).
    modifier onlySuperAdminOrOperator() {
        if (msg.sender != superAdmin && !isOperator[msg.sender]) revert NotSuperAdmin();
        _;
    }

    constructor(address usdcToken_, address treasury_, address vaultImplementation_, address priceOracle_) {
        if (
            usdcToken_ == address(0) || treasury_ == address(0) || vaultImplementation_ == address(0)
                || priceOracle_ == address(0)
        ) {
            revert ZeroAddress();
        }
        superAdmin = msg.sender;
        usdcToken = usdcToken_;
        treasury = treasury_;
        vaultImplementation = vaultImplementation_;
        priceOracle = priceOracle_;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Admin: super-admin transfer (two-step)
    // ══════════════════════════════════════════════════════════════════════════

    function setPendingSuperAdmin(address newSuperAdmin) external onlySuperAdmin {
        if (newSuperAdmin == address(0)) revert ZeroAddress();
        pendingSuperAdminAddr = newSuperAdmin;
        emit SuperAdminProposed(newSuperAdmin);
    }

    function acceptSuperAdmin() external {
        if (msg.sender != pendingSuperAdminAddr) revert NotPendingSuperAdmin();
        superAdmin = msg.sender;
        pendingSuperAdminAddr = address(0);
        emit SuperAdminAccepted(msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Admin: config
    // ══════════════════════════════════════════════════════════════════════════

    function updateTreasury(address treasury_) external onlySuperAdmin {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setEmergency(bool isEmergency_) external onlySuperAdmin {
        isEmergency = isEmergency_;
        emit EmergencySet(isEmergency_);
    }

    function setEtfCreationAuthority(address authority) external onlySuperAdmin {
        etfCreationAuthority = authority;
        emit EtfCreationAuthoritySet(authority);
    }

    /// @notice Rotates the price oracle used for NAV/rebalance valuation. Restricted to
    ///         super-admin — a compromised or misbehaving oracle can be swapped out without
    ///         redeploying the factory or any vault clone.
    function setPriceOracle(address oracle) external onlySuperAdmin {
        if (oracle == address(0)) revert ZeroAddress();
        priceOracle = oracle;
        emit PriceOracleSet(oracle);
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

    function setOperator(address account, bool isOperator_) external onlySuperAdmin {
        isOperator[account] = isOperator_;
        emit OperatorSet(account, isOperator_);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Asset registry
    // ══════════════════════════════════════════════════════════════════════════

    function createAsset(address mint) external onlySuperAdminOrOperator returns (uint64 assetId) {
        if (mint == address(0)) revert ZeroAddress();
        if (_mintRegistered[mint]) revert DuplicateMint();
        assetId = totalAssets;
        _assets[assetId] = AssetInfo({assetId: assetId, mint: mint, active: true, exists: true});
        _mintRegistered[mint] = true;
        totalAssets = assetId + 1;
        emit AssetCreated(assetId, mint);
    }

    /// @notice Toggles an asset's active flag — `active = false` is "remove" (assets are
    ///         never deleted, only deactivated, since existing vaults may still hold slots
    ///         referencing this assetId).
    function setAssetActive(uint64 assetId, bool active) external onlySuperAdminOrOperator {
        if (!_assets[assetId].exists) revert AssetMissing();
        _assets[assetId].active = active;
        emit AssetActiveSet(assetId, active);
    }

    function getAsset(uint64 assetId) external view returns (uint64, address, bool, bool) {
        AssetInfo storage a = _assets[assetId];
        return (a.assetId, a.mint, a.active, a.exists);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ETF factory
    // ══════════════════════════════════════════════════════════════════════════

    function createVault(CreateVaultParams calldata params) external returns (uint64 vaultId) {
        if (isEmergency) revert("EMERGENCY");

        address gate = etfCreationAuthority;
        if (gate == address(0)) revert CreationGateNotSet();
        if (msg.sender != gate && msg.sender != superAdmin) {
            revert UnauthorizedGateAuthority();
        }

        uint256 n = params.assetIds.length;
        if (n == 0) revert NoAssets();
        if (n > Constants.MAX_ASSETS) revert TooManyAssets();

        for (uint256 i = 0; i < n; i++) {
            AssetInfo storage a = _assets[params.assetIds[i]];
            if (!a.exists) revert AssetMissing();
            if (!a.active) revert AssetInactive();
            for (uint256 j = i + 1; j < n; j++) {
                if (params.assetIds[j] == params.assetIds[i]) revert AlreadyExists();
            }
        }

        vaultId = totalVaults;
        address clone = Clones.clone(vaultImplementation);
        vaultClones[vaultId] = clone;
        totalVaults = vaultId + 1;

        IVault(clone)
            .init(
                vaultId,
                msg.sender,
                params.feeRecipient == address(0) ? msg.sender : params.feeRecipient,
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
    // Path B relay + emergency-lock relay
    // ══════════════════════════════════════════════════════════════════════════

    function confirmWriteOff(uint64 vaultId, uint64 assetId) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        IVault(clone).executeWriteOff(assetId);
        emit WriteOffConfirmed(vaultId, assetId);
    }

    function confirmReactivate(uint64 vaultId, uint64 assetId) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        IVault(clone).executeReactivate(assetId);
        emit ReactivateConfirmed(vaultId, assetId);
    }

    function setVaultEmergencyLock(uint64 vaultId, bool locked) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        Vault(clone).setVaultEmergencyLock(locked);
    }
}
