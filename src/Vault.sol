// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IZenoIndexVault} from "./interfaces/IZenoIndexVault.sol";
import {IVault} from "./interfaces/IVault.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {ERC20Minimal} from "./tokens/ERC20Minimal.sol";
import {ShareToken} from "./tokens/ShareToken.sol";
import {VaultMath} from "./libraries/VaultMath.sol";
import {Constants} from "./libraries/Constants.sol";

/// @notice ERC-1167 clone implementation — one instance per ETF. Owns all per-vault storage.
///         Reads NAV/valuation, swap execution, and role/asset-registry data live from
///         `zenoIndexVault` on every call — never caches them.
contract Vault is Initializable, ReentrancyGuard, IVault {
    // ── Enums ─────────────────────────────────────────────────────────────────
    enum FundType {
        Fixed,
        Dynamic
    }

    // ── Structs ───────────────────────────────────────────────────────────────
    // ── Redeem state (per user) ──────────────────────────────────────────────────
    struct RedeemState {
        bool isRedeemActive;
        uint8 numAssets;
        uint256[20] assetAmountIn;
        bool[20] assetSwapped;
    }

    // ── Immutable-in-spirit (set once in init) ─────────────────────────────────
    address public zenoIndexVault;
    uint64 public vaultId;
    address public vaultManager;
    address public sharesToken;
    FundType public fundType;
    uint16 public depositFeeBps;
    uint16 public redeemFeeBps;
    uint256 public maxShares;

    // ── Mutable control ──────────────────────────────────────────────────────────
    address public feeRecipient;
    bool public paused;
    bool public adminLocked;

    // ── Genesis / share accounting ───────────────────────────────────────────────
    bool public genesisDone;
    uint256 public baselineSharePrice;
    uint256 public genesisSharesMinted;
    uint256 public totalShares;

    // ── Asset slots (parallel arrays, index = slot) ──────────────────────────────
    uint8 public numAssets;
    uint256 public totalPendingUsdc;
    uint64[20] internal _assetIds;
    uint16[20] internal _allocationBps;
    uint256[20] internal _usdcTargetAmount;
    uint256[20] internal _reservedAssets;

    // ── Path B: write-off state, keyed by assetId (not slot index — a written-off
    //    asset has no slot) ──────────────────────────────────────────────────────
    mapping(uint64 => bool) public isWrittenOff;
    mapping(uint64 => uint256) public writtenOffBalance; // snapshot at write-off time, informational
    mapping(uint64 => bool) public pendingWriteOff;
    mapping(uint64 => bool) public pendingReactivate;

    // ── Redeem accounting (per user) ──────────────────────────────────────────────
    uint256 public vaultRedeemEscrowTotal;
    /// @dev Count of RedeemStates with isRedeemActive == true. Every active RedeemState's
    ///      assetAmountIn/assetSwapped arrays are indexed against the slot layout as it
    ///      existed at requestRedeem time — _retireSlot's index-compaction desyncs any such
    ///      state (not just one with a nonzero reservation on the exact slot retiring), so
    ///      slot retirement is blocked outright while this is nonzero.
    uint256 public activeRedeemCount;
    mapping(address => RedeemState) internal redeemStates;
    mapping(address => uint256) public redeemUsdcBal;

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyManager() {
        if (msg.sender != vaultManager && !IZenoIndexVault(zenoIndexVault).isOperator(msg.sender)) {
            revert NotVaultManager();
        }
        _;
    }

    modifier onlyZenoIndexVault() {
        if (msg.sender != zenoIndexVault) revert NotZenoIndexVault();
        _;
    }

    // ── Events ────────────────────────────────────────────────────────────────
    event GenesisSeeded(address depositor, uint256 seedUsdc, uint256 baseline, uint256 sharesMinted);
    event Deposit(
        address user, uint256 usdcAmount, uint256 netUsdc, uint256 companyFee, uint256 managerFee, uint256 sharesMinted
    );
    event RequestRedeem(address user, uint256 sharesBurned, uint256 pendingUsdcCredited);
    event Claim(address user, uint256 grossUsdc, uint256 companyFee, uint256 managerFee, uint256 netUsdc);
    event SwapUsdcToAsset(uint8 assetIndex, uint256 usdcIn, uint256 assetOut);
    event SwapAssetToUsdc(address user, uint8 assetIndex, uint256 assetIn, uint256 usdcOut);
    event TargetAllocationsSet(uint64[] assetIds, uint16[] allocationBps);
    event RebalanceExecuted(uint8 assetIndex, uint256 amountTraded, bool wasSell);
    event WriteOffProposed(uint64 assetId);
    event WriteOffExecuted(uint64 assetId, uint256 balanceAtWriteOff, uint256 lastNavContribution);
    event ReactivateProposed(uint64 assetId);
    event ReactivateExecuted(uint64 assetId, uint256 restoredBalance);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotVaultManager();
    error NotZenoIndexVault();
    error VaultPaused();
    error VaultAdminLocked();
    error GenesisAlreadySeeded();
    error GenesisNotSeeded();
    error ZeroAmount();
    error InvalidAllocation();
    error TooManyAssets();
    error NoAssets();
    error ShareCapExceeded();
    error SlippageExceeded();
    error MissingMaxShares();
    error InsufficientShares();
    error RedeemAlreadyPending();
    error RedeemInactive();
    error NothingToClaim();
    error AssetNotSwapped();
    error AssetAlreadySwapped();
    error InvalidAssetIndex();
    error AssetNotFound();
    error AssetIsWrittenOff();
    error NotWrittenOff();
    error NoPendingWriteOff();
    error NoPendingReactivate();
    error SlotFull();
    error FeeOutOfBounds();
    error DuplicateAsset();
    error AssetReserved();
    error PathEnd();
    error AssetNotRegistered();
    error AssetNotActive();

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @dev The implementation contract itself is never a live vault — disable its initializer
    ///      so nobody can call `init` directly on it (only on clones).
    constructor() {
        _disableInitializers();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // External/public setters
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Post-clone initializer — the clone's constructor-equivalent.
    function init(
        uint64 vaultId_,
        address manager_,
        address feeRecipient_,
        uint16 depositFeeBps_,
        uint16 redeemFeeBps_,
        uint64[] calldata assetIds,
        uint16[] calldata allocationBps,
        uint8 fundType_,
        uint256 maxShares_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        if (depositFeeBps_ > Constants.MAX_DEPOSIT_FEE_BPS) revert FeeOutOfBounds();
        if (redeemFeeBps_ < Constants.MIN_REDEEM_FEE_BPS || redeemFeeBps_ > Constants.MAX_REDEEM_FEE_BPS) {
            revert FeeOutOfBounds();
        }

        zenoIndexVault = msg.sender; // ZenoIndexVault.sol is always the one that clones + calls init
        vaultId = vaultId_;
        vaultManager = manager_;
        feeRecipient = feeRecipient_ == address(0) ? manager_ : feeRecipient_;
        depositFeeBps = depositFeeBps_;
        redeemFeeBps = redeemFeeBps_;
        fundType = FundType(fundType_);

        uint256 n = assetIds.length;
        if (n == 0) revert NoAssets();
        if (n > Constants.MAX_ASSETS) revert TooManyAssets();
        if (allocationBps.length != n) revert InvalidAllocation();

        uint256 totalBps;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (assetIds[j] == assetIds[i]) revert DuplicateAsset();
            }
            _assetIds[i] = assetIds[i];
            _allocationBps[i] = allocationBps[i];
            totalBps += allocationBps[i];
        }
        if (totalBps != Constants.BPS_DENOM) revert InvalidAllocation();
        numAssets = uint8(n);

        if (fundType == FundType.Fixed) {
            if (maxShares_ == 0) revert MissingMaxShares();
            maxShares = maxShares_;
        }

        sharesToken = address(new ShareToken(name_, symbol_, address(this)));
    }

    // ── Control ───────────────────────────────────────────────────────────────

    function setPaused(bool paused_) external onlyManager {
        paused = paused_;
    }

    function setFeeRecipient(address feeRecipient_) external onlyManager {
        feeRecipient = feeRecipient_;
    }

    function setVaultEmergencyLock(bool locked) external onlyZenoIndexVault {
        adminLocked = locked;
    }

    // ── Genesis + Deposit ─────────────────────────────────────────────────────

    function genesisDeposit(uint256 baselineSharePrice_) external onlyManager nonReentrant {
        if (genesisDone) revert GenesisAlreadySeeded();

        uint256 genesisShares =
            VaultMath.calculateReverseGenesisShares(Constants.GENESIS_SEED_USDC, baselineSharePrice_);
        if (maxShares > 0 && genesisShares > maxShares) revert ShareCapExceeded();

        baselineSharePrice = baselineSharePrice_;
        totalShares = genesisShares;
        genesisSharesMinted = genesisShares;
        genesisDone = true;

        _recordPendingTargets(Constants.GENESIS_SEED_USDC);

        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        require(ERC20Minimal(usdc).transferFrom(msg.sender, address(this), Constants.GENESIS_SEED_USDC), "PULL");
        ShareToken(sharesToken).mint(address(this), genesisShares);

        emit GenesisSeeded(msg.sender, Constants.GENESIS_SEED_USDC, baselineSharePrice_, genesisShares);
    }

    function deposit(uint256 usdcAmount, uint256 minSharesOut) external nonReentrant returns (uint256 sharesMinted) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (paused) revert VaultPaused();
        if (adminLocked) revert VaultAdminLocked();
        if (!genesisDone) revert GenesisNotSeeded();

        uint256 navAssets = _sumNav();
        uint256 pendingUsdc = totalPendingUsdc;
        uint256 totalShares_ = totalShares;

        uint256 depositFee = (usdcAmount * uint256(depositFeeBps)) / Constants.BPS_DENOM;
        uint256 netUsdc = usdcAmount - depositFee;
        if (netUsdc == 0) revert ZeroAmount();

        sharesMinted = VaultMath.computeSharesToMint(netUsdc, totalShares_, navAssets, pendingUsdc);
        if (sharesMinted == 0) revert ZeroAmount();

        if (maxShares > 0 && totalShares_ + sharesMinted > maxShares) {
            uint256 remaining = maxShares - totalShares_;
            if (remaining == 0) revert ShareCapExceeded();
            uint256 navPlusPending = navAssets + pendingUsdc;
            uint256 clampedNet = VaultMath.computeUsdcForShares(remaining, totalShares_, navPlusPending);
            if (clampedNet == 0) revert ZeroAmount();
            uint256 clampedGross = (clampedNet * usdcAmount) / netUsdc;
            usdcAmount = clampedGross;
            netUsdc = clampedNet;
            sharesMinted = remaining;
        }

        if (sharesMinted < minSharesOut) revert SlippageExceeded();

        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        require(ERC20Minimal(usdc).transferFrom(msg.sender, address(this), usdcAmount), "PULL");

        VaultMath.FeeSplit memory fee = VaultMath.computeFeeSplit(usdcAmount, depositFeeBps);
        _payFees(usdc, fee);

        ShareToken(sharesToken).mint(msg.sender, sharesMinted);
        totalShares = totalShares_ + sharesMinted;

        _recordPendingTargets(netUsdc);

        emit Deposit(msg.sender, usdcAmount, netUsdc, fee.companyFee, fee.managerFee, sharesMinted);
    }

    // ── Redeem / claim ────────────────────────────────────────────────────────

    function requestRedeem(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        RedeemState storage rs = redeemStates[msg.sender];
        if (rs.isRedeemActive) revert RedeemAlreadyPending();

        ShareToken st = ShareToken(sharesToken);
        if (st.balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint8 n = numAssets;
        uint256 totalShares_ = totalShares;

        uint256[20] memory freeBalances;
        for (uint8 i = 0; i < n; i++) {
            (, address mint,,) = IZenoIndexVault(zenoIndexVault).getAsset(_assetIds[i]);
            uint256 bal = ERC20Minimal(mint).balanceOf(address(this));
            freeBalances[i] = bal > _reservedAssets[i] ? bal - _reservedAssets[i] : 0;
        }

        uint256[20] memory amounts = VaultMath.computeRedeemSwapAmounts(freeBalances, n, shares, totalShares_);

        ShareToken(sharesToken).burn(msg.sender, shares);
        totalShares = totalShares_ - shares;

        for (uint8 i = 0; i < n; i++) {
            _reservedAssets[i] += amounts[i];
        }

        VaultMath.PendingCarve memory carve =
            VaultMath.computePendingCarve(totalPendingUsdc, _usdcTargetAmount, n, shares, totalShares_);
        totalPendingUsdc = carve.totalPendingUsdc;
        _usdcTargetAmount = carve.usdcTargetAmount;

        if (carve.usdcSlice > 0) {
            redeemUsdcBal[msg.sender] += carve.usdcSlice;
            vaultRedeemEscrowTotal += carve.usdcSlice;
        }

        rs.isRedeemActive = true;
        rs.numAssets = n;
        rs.assetAmountIn = amounts;
        for (uint8 i = 0; i < n; i++) {
            rs.assetSwapped[i] = (amounts[i] == 0);
        }
        activeRedeemCount += 1;

        emit RequestRedeem(msg.sender, shares, carve.usdcSlice);
    }

    function claim() external nonReentrant {
        RedeemState storage rs = redeemStates[msg.sender];
        if (!rs.isRedeemActive) revert RedeemInactive();

        uint256 grossUsdc = redeemUsdcBal[msg.sender];
        if (grossUsdc == 0) revert NothingToClaim();

        for (uint8 i = 0; i < rs.numAssets; i++) {
            if (!rs.assetSwapped[i]) revert AssetNotSwapped();
        }

        VaultMath.FeeSplit memory fee = VaultMath.computeFeeSplit(grossUsdc, redeemFeeBps);
        redeemUsdcBal[msg.sender] = 0;
        vaultRedeemEscrowTotal -= grossUsdc;

        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        _payFees(usdc, fee);
        require(ERC20Minimal(usdc).transfer(msg.sender, fee.netAmount), "XFER");

        _resetRedeem(rs);
        emit Claim(msg.sender, grossUsdc, fee.companyFee, fee.managerFee, fee.netAmount);
    }

    // ── Inflow deployment leg ─────────────────────────────────────────────────

    function swapUsdcToAsset(uint8 assetIndex, address[] calldata path, uint256 minAssetOut)
        external
        onlyManager
        nonReentrant
    {
        if (assetIndex >= numAssets) revert InvalidAssetIndex();
        uint256 amount = _usdcTargetAmount[assetIndex];
        if (amount == 0) return;

        (, address mint,,) = IZenoIndexVault(zenoIndexVault).getAsset(_assetIds[assetIndex]);
        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        require(path[0] == usdc, "PATH_START");
        if (path[path.length - 1] != mint) revert PathEnd();

        address routerAddr = IZenoIndexVault(zenoIndexVault).router();
        ERC20Minimal(usdc).approve(routerAddr, amount);
        uint256 assetOut =
            IZenoIndexVault(zenoIndexVault).executeSwap(path, amount, minAssetOut, address(this), address(this));
        ERC20Minimal(usdc).approve(routerAddr, 0);

        totalPendingUsdc = totalPendingUsdc > amount ? totalPendingUsdc - amount : 0;
        _usdcTargetAmount[assetIndex] = 0;

        emit SwapUsdcToAsset(assetIndex, amount, assetOut);
    }

    // ── Redeem unwind leg ─────────────────────────────────────────────────────

    function swapAssetToUsdc(uint8 assetIndex, address[] calldata path, uint256 minUsdcOut) external nonReentrant {
        RedeemState storage rs = redeemStates[msg.sender];
        if (!rs.isRedeemActive) revert RedeemInactive();
        if (assetIndex >= numAssets) revert InvalidAssetIndex();
        if (rs.assetSwapped[assetIndex]) revert AssetAlreadySwapped();

        (, address mint,,) = IZenoIndexVault(zenoIndexVault).getAsset(_assetIds[assetIndex]);
        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        require(path[0] == mint && path[path.length - 1] == usdc, "PATH_ENDS");

        uint256 assetAmount = rs.assetAmountIn[assetIndex];
        if (assetAmount == 0) revert ZeroAmount();

        address routerAddr = IZenoIndexVault(zenoIndexVault).router();
        ERC20Minimal(mint).approve(routerAddr, assetAmount);
        uint256 usdcOut =
            IZenoIndexVault(zenoIndexVault).executeSwap(path, assetAmount, minUsdcOut, address(this), address(this));
        ERC20Minimal(mint).approve(routerAddr, 0);

        redeemUsdcBal[msg.sender] += usdcOut;
        vaultRedeemEscrowTotal += usdcOut;
        rs.assetSwapped[assetIndex] = true;
        _reservedAssets[assetIndex] =
            _reservedAssets[assetIndex] > assetAmount ? _reservedAssets[assetIndex] - assetAmount : 0;

        emit SwapAssetToUsdc(msg.sender, assetIndex, assetAmount, usdcOut);
    }

    // ── Path A: rebalance ─────────────────────────────────────────────────────

    /// @notice Sets the FULL target asset list + weights (not a diff). Diffs internally
    ///         against current slots: shared assets are reweighted, new assets claim a free
    ///         slot, dropped assets go to 0% (wind-down — see Vault.sol docs / spec §2.1).
    ///         No swaps happen in this call.
    function setTargetAllocations(uint64[] calldata assetIds, uint16[] calldata allocationBps) external onlyManager {
        uint256 n = assetIds.length;
        if (n == 0) revert NoAssets();
        if (n > Constants.MAX_ASSETS) revert TooManyAssets();
        if (allocationBps.length != n) revert InvalidAllocation();

        uint256 totalBps;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (assetIds[j] == assetIds[i]) revert DuplicateAsset();
            }
            totalBps += allocationBps[i];
        }
        if (totalBps != Constants.BPS_DENOM) revert InvalidAllocation();

        uint8 oldN = numAssets;
        // Zero out weight on every currently-held asset not present in the new list
        // (wind-down) — done first so the pass below can freely overwrite slots.
        for (uint8 i = 0; i < oldN; i++) {
            uint64 existingId = _assetIds[i];
            bool stillPresent = false;
            for (uint256 j = 0; j < n; j++) {
                if (assetIds[j] == existingId) {
                    stillPresent = true;
                    break;
                }
            }
            if (!stillPresent) _allocationBps[i] = 0;
        }

        for (uint256 j = 0; j < n; j++) {
            uint64 id = assetIds[j];
            if (isWrittenOff[id]) revert AssetIsWrittenOff();

            // Reject an assetId that was never registered on ZenoIndexVault.sol (or was
            // deactivated) — accepting it here would store a slot whose getAsset(id) later
            // resolves to mint == address(0), and every NAV read (_sumNav -> ZenoIndexVault.sumNav
            // -> ERC20Minimal(address(0)).balanceOf(...)) then reverts, permanently
            // bricking deposit/redeem/rebalance for the whole vault.
            (,, bool active, bool exists) = IZenoIndexVault(zenoIndexVault).getAsset(id);
            if (!exists) revert AssetNotRegistered();
            if (!active) revert AssetNotActive();

            int256 existingSlot = -1;
            for (uint8 i = 0; i < oldN; i++) {
                if (_assetIds[i] == id) {
                    existingSlot = int256(uint256(i));
                    break;
                }
            }
            if (existingSlot >= 0) {
                _allocationBps[uint256(existingSlot)] = allocationBps[j];
            } else {
                // New asset: claim the first free slot (a slot beyond current numAssets, or
                // a retired slot — retired slots are compacted out by executeRebalance, so
                // by the time we get here any freed slot is already past-`numAssets` territory
                // handled by simply appending).
                if (numAssets >= Constants.MAX_ASSETS) revert SlotFull();
                uint8 newSlot = numAssets;
                _assetIds[newSlot] = id;
                _allocationBps[newSlot] = allocationBps[j];
                numAssets = newSlot + 1;
            }
        }

        emit TargetAllocationsSet(assetIds, allocationBps);
    }

    /// @notice Trades ONLY the delta between assetIndex's current NAV weight and its target.
    ///         Skips (no-op) if within Constants.REBALANCE_DRIFT_BPS of target. Manager-only.
    function executeRebalance(uint8 assetIndex, address[] calldata path, uint256 minOut)
        external
        onlyManager
        nonReentrant
    {
        if (assetIndex >= numAssets) revert InvalidAssetIndex();

        uint256 nav = _sumNav();
        if (nav == 0) return;

        (, address mint,,) = IZenoIndexVault(zenoIndexVault).getAsset(_assetIds[assetIndex]);
        uint256 bal = ERC20Minimal(mint).balanceOf(address(this));
        uint256 free = bal > _reservedAssets[assetIndex] ? bal - _reservedAssets[assetIndex] : 0;

        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        uint256 currentValueUsdc = IZenoIndexVault(zenoIndexVault).valueUsdc(mint, free);

        uint256 currentBps = (currentValueUsdc * Constants.BPS_DENOM) / nav;
        uint256 targetBps = _allocationBps[assetIndex];

        uint256 driftBps = currentBps > targetBps ? currentBps - targetBps : targetBps - currentBps;
        if (driftBps <= Constants.REBALANCE_DRIFT_BPS) return;

        address routerAddr = IZenoIndexVault(zenoIndexVault).router();

        if (currentBps > targetBps) {
            // Overweight: sell the delta down to USDC — path must start at the asset and
            // end at USDC (a caller-chosen intermediate hub is allowed in between).
            uint256 deltaValueUsdc = ((currentBps - targetBps) * nav) / Constants.BPS_DENOM;
            uint256 sellAmount = currentValueUsdc == 0 ? 0 : (free * deltaValueUsdc) / currentValueUsdc;
            if (sellAmount == 0) return;
            require(path[0] == mint, "PATH_START");
            if (path[path.length - 1] != usdc) revert PathEnd();
            ERC20Minimal(mint).approve(routerAddr, sellAmount);
            IZenoIndexVault(zenoIndexVault).executeSwap(path, sellAmount, minOut, address(this), address(this));
            ERC20Minimal(mint).approve(routerAddr, 0);
            emit RebalanceExecuted(assetIndex, sellAmount, true);
        } else {
            // Underweight: buy the delta, funded only from USDC that isn't already earmarked
            // for another asset's deployment leg (totalPendingUsdc) or owed to redeemers
            // in escrow (vaultRedeemEscrowTotal) — spending either would leave those
            // obligations unbacked by real balance.
            uint256 deltaValueUsdc = ((targetBps - currentBps) * nav) / Constants.BPS_DENOM;
            uint256 usdcBal = ERC20Minimal(usdc).balanceOf(address(this));
            uint256 earmarked = totalPendingUsdc + vaultRedeemEscrowTotal;
            uint256 usdcFree = usdcBal > earmarked ? usdcBal - earmarked : 0;
            uint256 buyAmount = deltaValueUsdc < usdcFree ? deltaValueUsdc : usdcFree;
            if (buyAmount == 0) return;
            require(path[0] == usdc, "PATH_START");
            if (path[path.length - 1] != mint) revert PathEnd();
            ERC20Minimal(usdc).approve(routerAddr, buyAmount);
            IZenoIndexVault(zenoIndexVault).executeSwap(path, buyAmount, minOut, address(this), address(this));
            ERC20Minimal(usdc).approve(routerAddr, 0);
            emit RebalanceExecuted(assetIndex, buyAmount, false);
        }

        // If this slot's target is 0 and its balance has hit zero, compact it out — but
        // only when no redeem is in flight (see _retireSlot). Skipping here is safe: the
        // slot just stays at 0% until a later rebalance call retires it once redeems clear.
        if (_allocationBps[assetIndex] == 0) {
            uint256 remainingBal = ERC20Minimal(mint).balanceOf(address(this));
            if (remainingBal == 0 && _reservedAssets[assetIndex] == 0 && activeRedeemCount == 0) {
                _retireSlot(assetIndex);
            }
        }
    }

    // ── Path B: write-off (manager proposes, super-admin confirms via ZenoIndexVault relay) ──

    function proposeWriteOff(uint64 assetId) external onlyManager {
        pendingWriteOff[assetId] = true;
        emit WriteOffProposed(assetId);
    }

    function proposeReactivate(uint64 assetId) external onlyManager {
        if (!isWrittenOff[assetId]) revert NotWrittenOff();
        pendingReactivate[assetId] = true;
        emit ReactivateProposed(assetId);
    }

    /// @dev Called only by ZenoIndexVault.sol (`onlyZenoIndexVault`), which itself enforces `onlySuperAdmin`.
    function executeWriteOff(uint64 assetId) external onlyZenoIndexVault {
        if (!pendingWriteOff[assetId]) revert NoPendingWriteOff();
        pendingWriteOff[assetId] = false;

        uint8 slot = _slotOf(assetId);
        // Any active redeem's RedeemState is indexed against the slot layout as it existed
        // at requestRedeem time — _retireSlot's index-compaction desyncs it regardless of
        // which slot retires, not only one with a nonzero reservation on this exact slot.
        // Block until every in-flight redeem clears (via claim).
        if (activeRedeemCount > 0) revert AssetReserved();
        (, address mint,,) = IZenoIndexVault(zenoIndexVault).getAsset(assetId);
        uint256 bal = ERC20Minimal(mint).balanceOf(address(this));
        uint256 navContribution;
        if (bal > 0) {
            navContribution = IZenoIndexVault(zenoIndexVault).valueUsdc(mint, bal);
        }

        isWrittenOff[assetId] = true;
        writtenOffBalance[assetId] = bal;
        _retireSlot(slot);

        emit WriteOffExecuted(assetId, bal, navContribution);
    }

    /// @dev Called only by ZenoIndexVault.sol (`onlyZenoIndexVault`), which itself enforces `onlySuperAdmin`.
    function executeReactivate(uint64 assetId) external onlyZenoIndexVault {
        if (!pendingReactivate[assetId]) revert NoPendingReactivate();
        pendingReactivate[assetId] = false;
        if (!isWrittenOff[assetId]) revert NotWrittenOff();

        isWrittenOff[assetId] = false;
        uint256 restoredBalance = writtenOffBalance[assetId];
        writtenOffBalance[assetId] = 0;

        if (numAssets >= Constants.MAX_ASSETS) revert SlotFull();
        uint8 newSlot = numAssets;
        _assetIds[newSlot] = assetId;
        _allocationBps[newSlot] = 0; // reactivated at 0% target — manager re-weights separately
        numAssets = newSlot + 1;

        emit ReactivateExecuted(assetId, restoredBalance);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Private/internal setters
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Every caller must ensure activeRedeemCount == 0 first (see executeWriteOff and
    ///      executeRebalance) — compaction below shifts the last slot's data into `index`,
    ///      which desyncs any RedeemState still indexed against the pre-compaction layout.
    ///      Asserted here too as a last-line invariant, not just documented at call sites.
    function _retireSlot(uint8 index) internal {
        assert(activeRedeemCount == 0);
        // Drop this slot's undeployed pending before compacting — otherwise totalPendingUsdc
        // keeps earmarking USDC that can never be swapped via the retired assetId.
        uint256 pending = _usdcTargetAmount[index];
        if (pending > 0) {
            totalPendingUsdc = totalPendingUsdc > pending ? totalPendingUsdc - pending : 0;
        }

        uint8 last = numAssets - 1;
        if (index != last) {
            _assetIds[index] = _assetIds[last];
            _allocationBps[index] = _allocationBps[last];
            _usdcTargetAmount[index] = _usdcTargetAmount[last];
            _reservedAssets[index] = _reservedAssets[last];
        }
        _assetIds[last] = 0;
        _allocationBps[last] = 0;
        _usdcTargetAmount[last] = 0;
        _reservedAssets[last] = 0;
        numAssets = last;
    }

    function _recordPendingTargets(uint256 netUsdc) internal {
        address usdc = IZenoIndexVault(zenoIndexVault).usdcToken();
        uint8 n = numAssets;
        for (uint8 i = 0; i < n; i++) {
            (, address mint,,) = IZenoIndexVault(zenoIndexVault).getAsset(_assetIds[i]);
            uint256 sliceUsdc = VaultMath.allocationSlice(netUsdc, _allocationBps[i]);
            if (mint == usdc) continue;
            _usdcTargetAmount[i] += sliceUsdc;
            totalPendingUsdc += sliceUsdc;
        }
    }

    function _payFees(address usdc, VaultMath.FeeSplit memory fee) internal {
        if (fee.companyFee > 0) {
            require(ERC20Minimal(usdc).transfer(IZenoIndexVault(zenoIndexVault).treasury(), fee.companyFee), "FEE_T");
        }
        if (fee.managerFee > 0) {
            require(ERC20Minimal(usdc).transfer(feeRecipient, fee.managerFee), "FEE_M");
        }
    }

    function _resetRedeem(RedeemState storage rs) internal {
        rs.isRedeemActive = false;
        rs.numAssets = 0;
        for (uint8 i = 0; i < Constants.MAX_ASSETS; i++) {
            rs.assetAmountIn[i] = 0;
            rs.assetSwapped[i] = false;
        }
        activeRedeemCount -= 1;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Getters
    // ══════════════════════════════════════════════════════════════════════════

    // ── Asset slot getters ────────────────────────────────────────────────────

    function assetIdAt(uint8 index) external view returns (uint64) {
        require(index < numAssets, "IDX");
        return _assetIds[index];
    }

    function allocationBpsAt(uint8 index) external view returns (uint16) {
        require(index < numAssets, "IDX");
        return _allocationBps[index];
    }

    function usdcTargetAmountAt(uint8 index) external view returns (uint256) {
        require(index < numAssets, "IDX");
        return _usdcTargetAmount[index];
    }

    function reservedAt(uint8 index) external view returns (uint256) {
        require(index < numAssets, "IDX");
        return _reservedAssets[index];
    }

    // ── Deposit / NAV views ───────────────────────────────────────────────────

    function previewDeposit(uint256 usdcAmount)
        external
        view
        returns (uint256 sharesOut, uint256 netUsdc, uint256 companyFee, uint256 managerFee)
    {
        VaultMath.FeeSplit memory fee = VaultMath.computeFeeSplit(usdcAmount, depositFeeBps);
        netUsdc = fee.netAmount;
        companyFee = fee.companyFee;
        managerFee = fee.managerFee;
        if (!genesisDone || netUsdc == 0) return (0, netUsdc, companyFee, managerFee);
        sharesOut = VaultMath.computeSharesToMint(netUsdc, totalShares, _sumNav(), totalPendingUsdc);
    }

    function totalNav() external view returns (uint256) {
        return _sumNav() + totalPendingUsdc;
    }

    // ── Redeem state views ────────────────────────────────────────────────────

    function getRedeemState(address user) external view returns (bool active, uint8 numAssets_, uint256 escrowUsdc) {
        RedeemState storage rs = redeemStates[user];
        return (rs.isRedeemActive, rs.numAssets, redeemUsdcBal[user]);
    }

    function getRedeemAssetAmount(address user, uint8 index) external view returns (uint256 amountIn, bool swapped) {
        RedeemState storage rs = redeemStates[user];
        return (rs.assetAmountIn[index], rs.assetSwapped[index]);
    }

    // ── Internal views ────────────────────────────────────────────────────────

    function _sumNav() internal view returns (uint256) {
        uint8 n = numAssets;
        uint64[] memory ids = new uint64[](n);
        uint256[] memory reserved = new uint256[](n);
        for (uint8 i = 0; i < n; i++) {
            ids[i] = _assetIds[i];
            reserved[i] = _reservedAssets[i];
        }
        return IZenoIndexVault(zenoIndexVault)
            .sumNav(address(this), ids, reserved, totalPendingUsdc + vaultRedeemEscrowTotal);
    }

    function _slotOf(uint64 assetId) internal view returns (uint8) {
        uint8 n = numAssets;
        for (uint8 i = 0; i < n; i++) {
            if (_assetIds[i] == assetId) return i;
        }
        revert AssetNotFound();
    }
}
