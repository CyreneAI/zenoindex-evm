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

    // ── Price safety rails ───────────────────────────────────────────────────
    /// @dev Last `setPrice`/`setPriceWhole` timestamp per token.
    mapping(address => uint256) public priceUpdatedAt;
    /// @notice A price older than this reverts every quote (StalePrice). 0 disables.
    uint256 public maxPriceAge = 1 days;
    /// @notice Max move of one price update vs the previous price, in bps. 0 disables.
    uint16 public maxPriceChangeBps = 2_000;
    /// @notice Swap floor: every swap's minAmountOut is raised to at least the price-table
    ///         quote minus this many bps. 10_000 disables the floor.
    uint16 public maxSwapSlippageBps = 300;

    // ── Vault (clone) registry ────────────────────────────────────────────────
    uint64 public totalVaults;
    mapping(uint64 => address) public vaultClones;
    mapping(address => bool) public isVaultClone;

    // ── Vault creation + per-vault operators ─────────────────────────────────
    /// @notice Accounts super-admin allows to call `createVault` (super-admin always can).
    mapping(address => bool) public isVaultCreator;
    /// @notice vault clone => account => may act as that vault's manager.
    mapping(address => mapping(address => bool)) public isVaultOperator;

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
    event WrittenOffSwept(uint64 indexed vaultId, uint64 indexed assetId, address to);
    event VaultCreatorSet(address indexed account, bool allowed);
    event VaultOperatorSet(uint64 indexed vaultId, address indexed account, bool allowed);
    event MaxPriceAgeSet(uint256 maxPriceAge);
    event MaxPriceChangeBpsSet(uint16 maxPriceChangeBps);
    event MaxSwapSlippageBpsSet(uint16 maxSwapSlippageBps);

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
    error NotVaultCreator();
    error NotVaultClone();
    error InvalidSwapSource();
    error Emergency();
    error ZeroPrice();
    error StalePrice(address token);
    error PriceChangeTooLarge(address token);
    error VaultsExist();
    error InvalidBps();

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
    ///      token), so it reverts once any vault exists.
    function setUsdcToken(address newUsdcToken) external onlySuperAdmin {
        if (newUsdcToken == address(0)) revert ZeroAddress();
        if (totalVaults > 0) revert VaultsExist();
        emit UsdcTokenSet(usdcToken, newUsdcToken);
        usdcToken = newUsdcToken;
    }

    /// @notice Sets raw price: `usdcOut` USDC (6 dec) for `tokenIn` raw token units.
    /// @dev Stays callable during emergency so a bad price can be corrected while
    ///      everything that moves value is frozen.
    function setPrice(address token, uint256 usdcOut, uint256 tokenIn) external onlySuperAdmin {
        if (token == address(0)) revert ZeroAddress();
        _setPrice(token, usdcOut, tokenIn);
    }

    /// @dev Convenience: USD price for 1 whole token (accounts for decimals).
    ///      e.g. token 6 dec at $2 → setPriceWhole(token, 2_000_000)
    function setPriceWhole(address token, uint256 usdcPerWholeToken) external onlySuperAdmin {
        if (token == address(0)) revert ZeroAddress();
        _setPrice(token, usdcPerWholeToken, 10 ** uint256(ERC20Minimal(token).decimals()));
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlySuperAdmin {
        maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeSet(maxPriceAge_);
    }

    function setMaxPriceChangeBps(uint16 maxPriceChangeBps_) external onlySuperAdmin {
        maxPriceChangeBps = maxPriceChangeBps_;
        emit MaxPriceChangeBpsSet(maxPriceChangeBps_);
    }

    function setMaxSwapSlippageBps(uint16 maxSwapSlippageBps_) external onlySuperAdmin {
        if (maxSwapSlippageBps_ > Constants.BPS_DENOM) revert InvalidBps();
        maxSwapSlippageBps = maxSwapSlippageBps_;
        emit MaxSwapSlippageBpsSet(maxSwapSlippageBps_);
    }

    /// @notice Sets the DEX-execution router address that clones swap through day to day.
    function setSwapRouter(address newRouter) external onlySuperAdmin {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(router, newRouter);
        router = newRouter;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters — vault creators + per-vault operators
    // ══════════════════════════════════════════════════════════════════════════

    function setVaultCreator(address account, bool allowed) external onlySuperAdmin {
        if (account == address(0)) revert ZeroAddress();
        isVaultCreator[account] = allowed;
        emit VaultCreatorSet(account, allowed);
    }

    /// @notice Grants/revokes manager powers on ONE vault. Operators are scoped per vault so
    ///         a leaked operator key cannot touch every vault in the protocol.
    function setVaultOperator(uint64 vaultId, address account, bool allowed) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        if (account == address(0)) revert ZeroAddress();
        isVaultOperator[clone][account] = allowed;
        emit VaultOperatorSet(vaultId, account, allowed);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters — asset registry
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Registers an asset. Fee-on-transfer and rebasing tokens are NOT supported
    ///         and must not be registered: redeem reservations and NAV assume 1:1 transfers
    ///         and stable balances. (Vault swaps measure output by balance delta and a
    ///         fee-on-transfer input makes the router's payment revert, so such a token fails
    ///         loudly rather than silently mis-accounting — but it would still be unusable.)
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

    /// @notice Super-admin or an allowlisted vault creator only — so every entry in
    ///         `vaultClones` is an official vault. The router and a price for every
    ///         non-USDC asset must already be set.
    function createVault(
        CreateVaultParams calldata params
    ) external returns (uint64 vaultId) {
        if (isEmergency) revert Emergency();
        if (msg.sender != IAccessMaster(accessMaster).superAdmin() && !isVaultCreator[msg.sender]) {
            revert NotVaultCreator();
        }
        if (router == address(0)) revert NoRouter();

        uint256 n = params.assetIds.length;
        if (n == 0) revert NoAssets();
        if (n > Constants.MAX_ASSETS) revert TooManyAssets();

        for (uint256 i = 0; i < n; i++) {
            AssetInfo storage a = _assets[params.assetIds[i]];
            if (!a.exists) revert AssetMissing();
            if (!a.active) revert AssetInactive();
            if (a.mint != usdcToken && priceDen[a.mint] == 0) revert NoPrice();
            for (uint256 j = i + 1; j < n; j++) {
                if (params.assetIds[j] == params.assetIds[i])
                    revert AlreadyExists();
            }
        }

        vaultId = totalVaults;
        address clone = Clones.clone(vaultImplementation);
        vaultClones[vaultId] = clone;
        isVaultClone[clone] = true;
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

    /// @notice Moves a written-off asset's whole balance out of the vault to `to`.
    function sweepWrittenOff(uint64 vaultId, uint64 assetId, address to) external onlySuperAdmin {
        address clone = vaultClones[vaultId];
        if (clone == address(0)) revert VaultNotFound();
        if (to == address(0)) revert ZeroAddress();
        IVault(clone).executeSweep(assetId, to);
        emit WrittenOffSwept(vaultId, assetId, to);
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
    ///         Only registered vault clones may call, only for their own tokens, and never
    ///         during emergency. `minAmountOut` is raised to the price-table floor.
    /// @dev `from` (the calling Vault.sol clone) must have approved `router` directly —
    ///      this contract never custodies the tokens, it only orchestrates the call.
    function executeSwap(address[] calldata path, uint256 amountIn, uint256 minAmountOut, address from, address to)
        external
        returns (uint256 amountOut)
    {
        if (!isVaultClone[msg.sender]) revert NotVaultClone();
        if (from != msg.sender) revert InvalidSwapSource();
        if (isEmergency) revert Emergency();
        address r = router;
        if (r == address(0)) revert NoRouter();
        uint256 floor = swapFloor(path[0], path[path.length - 1], amountIn);
        if (floor > minAmountOut) minAmountOut = floor;
        amountOut = ISwapRouter(r).swap(path, amountIn, minAmountOut, from, to);
    }

    /// @notice Minimum acceptable output for swapping `amountIn` of `tokenIn` to `tokenOut`:
    ///         the price-table quote less `maxSwapSlippageBps`.
    function swapFloor(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 slip = maxSwapSlippageBps;
        if (slip >= Constants.BPS_DENOM) return 0;
        uint256 usdcValue = tokenIn == usdcToken ? amountIn : _quote(tokenIn, amountIn);
        uint256 expectedOut;
        if (tokenOut == usdcToken) {
            expectedOut = usdcValue;
        } else {
            _checkFresh(tokenOut);
            uint256 num = priceNum[tokenOut];
            if (num == 0) revert NoPrice();
            expectedOut = (usdcValue * priceDen[tokenOut]) / num;
        }
        return (expectedOut * (Constants.BPS_DENOM - slip)) / Constants.BPS_DENOM;
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
        _checkFresh(token);
        return (amount * priceNum[token]) / den;
    }

    function _checkFresh(address token) internal view {
        uint256 age = maxPriceAge;
        if (age != 0 && block.timestamp > priceUpdatedAt[token] + age) revert StalePrice(token);
    }

    function _setPrice(address token, uint256 usdcOut, uint256 tokenIn) internal {
        if (usdcOut == 0 || tokenIn == 0) revert ZeroPrice();
        uint256 oldNum = priceNum[token];
        uint256 oldDen = priceDen[token];
        uint256 bound = maxPriceChangeBps;
        if (bound != 0 && oldDen != 0) {
            // Compare per-unit prices by cross-multiplying: new = usdcOut/tokenIn, old = oldNum/oldDen.
            uint256 newScaled = usdcOut * oldDen;
            uint256 oldScaled = oldNum * tokenIn;
            uint256 diff = newScaled > oldScaled ? newScaled - oldScaled : oldScaled - newScaled;
            if (diff * Constants.BPS_DENOM > oldScaled * bound) revert PriceChangeTooLarge(token);
        }
        priceNum[token] = usdcOut;
        priceDen[token] = tokenIn;
        priceUpdatedAt[token] = block.timestamp;
        emit PriceSet(token, usdcOut, tokenIn);
    }
}
