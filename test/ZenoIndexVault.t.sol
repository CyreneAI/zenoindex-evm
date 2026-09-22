// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {NavCalculation} from "../src/NavCalculation.sol";
import {SwapExecutor} from "../src/SwapExecutor.sol";
import {AccessMaster} from "../src/AccessMaster.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {ShareToken} from "../src/tokens/ShareToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract ZenoIndexVaultTest is Test {
    ZenoIndexVault internal zenoIndexVault;
    Vault internal vaultImpl;
    NavCalculation internal navCalculation;
    SwapExecutor internal swapExecutor;
    AccessMaster internal accessMaster;
    MockERC20 internal usdc;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    // Real Uniswap V4 execution venue — swaps go through an actual PoolManager/pool,
    // not a fixed-rate stand-in, so swap outputs below reflect real AMM price impact.
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal liquidityRouter;
    UniswapV4Adapter internal router;

    address internal treasury = address(0xA11);
    address internal manager = address(0xB22);
    address internal feeRecipient = address(0xC33);
    address internal user = address(0xD44);
    address internal dexAdmin = address(0xDEC0);
    address internal lp = address(0x11);

    uint64 internal assetA;
    uint64 internal assetB;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant POOL_TICK_SPACING = 10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tokenA = new MockERC20("Token A", "TKA", 6);
        tokenB = new MockERC20("Token B", "TKB", 6);
        poolManager = new PoolManager(address(this));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        router = new UniswapV4Adapter(address(poolManager), dexAdmin);

        vaultImpl = new Vault();
        navCalculation = new NavCalculation();
        accessMaster = new AccessMaster(address(this), treasury);
        zenoIndexVault = new ZenoIndexVault(address(usdc), address(vaultImpl), address(accessMaster));
        swapExecutor = new SwapExecutor(address(zenoIndexVault));

        zenoIndexVault.setPricingModule(address(navCalculation));
        zenoIndexVault.setSwapModule(address(swapExecutor));
        zenoIndexVault.setSwapRouter(address(router));

        _initPoolAndSeed(address(usdc), address(tokenA));
        _initPoolAndSeed(address(usdc), address(tokenB));

        navCalculation.setPriceWhole(address(tokenA), 1_000_000);
        navCalculation.setPriceWhole(address(tokenB), 1_000_000);

        assetA = zenoIndexVault.createAsset(address(tokenA));
        assetB = zenoIndexVault.createAsset(address(tokenB));

        usdc.mint(manager, 10_000_000e6);
        usdc.mint(user, 10_000_000e6);
    }

    /// @dev Registers a real V4 pool for `x`/`y` on `router` and seeds it with deep,
    ///      balanced LP liquidity around a 1:1 price so ordinary-sized swaps in these
    ///      tests see only minor price impact.
    function _initPoolAndSeed(address x, address y) internal {
        (address c0, address c1) = x < y ? (x, y) : (y, x);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(key, SQRT_PRICE_1_1);

        MockERC20(c0).mint(lp, 1_000_000_000e6);
        MockERC20(c1).mint(lp, 1_000_000_000e6);
        vm.startPrank(lp);
        MockERC20(c0).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(c1).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 500_000_000e6, salt: 0
            }),
            ""
        );
        vm.stopPrank();

        vm.prank(dexAdmin);
        router.setPool(c0, c1, POOL_FEE, POOL_TICK_SPACING, address(0));
    }

    function _createDirectVault(uint16 depositFeeBps, uint16 redeemFeeBps, uint256 maxShares)
        internal
        returns (Vault v)
    {
        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6000;
        bps[1] = 4000;

        ZenoIndexVault.CreateVaultParams memory p = ZenoIndexVault.CreateVaultParams({
            feeRecipient: feeRecipient,
            depositFeeBps: depositFeeBps,
            redeemFeeBps: redeemFeeBps,
            assetIds: ids,
            allocationBps: bps,
            fundType: maxShares > 0 ? 0 : 1,
            maxShares: maxShares,
            name: "Test Vault",
            symbol: "tVLT"
        });

        vm.prank(manager);
        uint64 id = zenoIndexVault.createVault(p);
        v = Vault(zenoIndexVault.vaultClones(id));
    }

    function _genesis(Vault v, uint256 baseline) internal {
        vm.startPrank(manager);
        usdc.approve(address(v), Constants.GENESIS_SEED_USDC);
        v.genesisDeposit(baseline);
        vm.stopPrank();
    }

    // ── Clone isolation ─────────────────────────────────────────────────────────

    function test_TwoVaults_HaveIndependentStorage() public {
        Vault v1 = _createDirectVault(100, 50, 0);
        Vault v2 = _createDirectVault(0, 200, 0);

        assertTrue(address(v1) != address(v2));
        assertEq(v1.depositFeeBps(), 100);
        assertEq(v2.depositFeeBps(), 0);
        assertEq(v1.redeemFeeBps(), 50);
        assertEq(v2.redeemFeeBps(), 200);
    }

    function test_SwapModule_AddressChangePropagatesToExistingClone() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        // A second real adapter instance pointed at the same PoolManager/pools.
        UniswapV4Adapter newRouter = new UniswapV4Adapter(address(poolManager), dexAdmin);
        vm.prank(dexAdmin);
        newRouter.setPool(address(usdc), address(tokenA), POOL_FEE, POOL_TICK_SPACING, address(0));

        zenoIndexVault.setSwapRouter(address(newRouter));

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(tokenA);

        // v was created before the router swap, but reads the CURRENT router live —
        // no re-init needed for the new router to take effect.
        vm.prank(manager);
        v.swapUsdcToAsset(0, path, 0);
        assertGt(tokenA.balanceOf(address(v)), 0);
    }

    // ── Full lifecycle ────────────────────────────────────────────────────────

    function test_InitCreateGenesisDepositRedeemClaim() public {
        Vault v = _createDirectVault(100, 50, 0);
        uint256 baseline = 1_000_000_000;
        _genesis(v, baseline);

        assertTrue(v.genesisDone());
        assertEq(v.baselineSharePrice(), baseline);
        uint256 expectedGenesis = (Constants.GENESIS_SEED_USDC * Constants.PRICE_SCALE) / baseline;
        assertEq(v.totalShares(), expectedGenesis);
        assertEq(ShareToken(v.sharesToken()).balanceOf(address(v)), expectedGenesis);

        uint256 depositAmt = 100_000_000;
        vm.startPrank(user);
        usdc.approve(address(v), depositAmt);
        (uint256 previewShares, uint256 netUsdc, uint256 companyFee, uint256 managerFee) = v.previewDeposit(depositAmt);
        assertEq(netUsdc, 99_000_000);
        assertEq(companyFee, 200_000);
        assertEq(managerFee, 800_000);

        uint256 sharesOut = v.deposit(depositAmt, previewShares);
        vm.stopPrank();
        assertEq(sharesOut, previewShares);
        assertEq(usdc.balanceOf(treasury), companyFee);
        assertEq(usdc.balanceOf(feeRecipient), managerFee);

        address[] memory pathA = new address[](2);
        pathA[0] = address(usdc);
        pathA[1] = address(tokenA);
        address[] memory pathB = new address[](2);
        pathB[0] = address(usdc);
        pathB[1] = address(tokenB);
        vm.startPrank(manager);
        v.swapUsdcToAsset(0, pathA, 0);
        v.swapUsdcToAsset(1, pathB, 0);
        vm.stopPrank();
        assertEq(v.usdcTargetAmountAt(0), 0);
        assertEq(v.usdcTargetAmountAt(1), 0);

        uint256 userShares = ShareToken(v.sharesToken()).balanceOf(user);
        uint256 redeemShares = userShares / 2;
        vm.prank(user);
        v.requestRedeem(redeemShares);

        (bool active,,) = v.getRedeemState(user);
        assertTrue(active);

        address[] memory redeemPathA = new address[](2);
        redeemPathA[0] = address(tokenA);
        redeemPathA[1] = address(usdc);
        address[] memory redeemPathB = new address[](2);
        redeemPathB[0] = address(tokenB);
        redeemPathB[1] = address(usdc);

        vm.startPrank(user);
        v.swapAssetToUsdc(0, redeemPathA, 0);
        v.swapAssetToUsdc(1, redeemPathB, 0);
        uint256 escrowBefore = v.redeemUsdcBal(user);
        assertTrue(escrowBefore > 0);

        uint256 userUsdcBefore = usdc.balanceOf(user);
        v.claim();
        vm.stopPrank();

        (bool activeAfter,,) = v.getRedeemState(user);
        assertFalse(activeAfter);
        assertTrue(usdc.balanceOf(user) > userUsdcBefore);
    }

    // ── Path A rebalance ──────────────────────────────────────────────────────

    function test_SetTargetAllocations_ReweightsExistingAssets() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3000;
        bps[1] = 7000;

        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        assertEq(v.allocationBpsAt(0), 3000);
        assertEq(v.allocationBpsAt(1), 7000);
    }

    function test_SetTargetAllocations_AddsNewAssetAtFreeSlot() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        MockERC20 tokenC = new MockERC20("Token C", "TKC", 6);
        uint64 assetC = zenoIndexVault.createAsset(address(tokenC));

        uint64[] memory ids = new uint64[](3);
        ids[0] = assetA;
        ids[1] = assetB;
        ids[2] = assetC;
        uint16[] memory bps = new uint16[](3);
        bps[0] = 3000;
        bps[1] = 3000;
        bps[2] = 4000;

        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        assertEq(v.numAssets(), 3);
        assertEq(v.assetIdAt(2), assetC);
        assertEq(v.allocationBpsAt(2), 4000);
    }

    function test_SetTargetAllocations_DroppedAssetGoesToZeroNotRemoved() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint64[] memory ids = new uint64[](1);
        ids[0] = assetA;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;

        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        // assetB dropped from target list but still occupies its slot (wind-down) since
        // numAssets only shrinks via executeRebalance's auto-retire once balance hits zero.
        assertEq(v.numAssets(), 2);
        assertEq(v.allocationBpsAt(1), 0);
    }

    function test_SetTargetAllocations_RevertsForNonManager() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;

        vm.prank(user);
        vm.expectRevert(Vault.NotVaultManager.selector);
        v.setTargetAllocations(ids, bps);
    }

    function test_SetTargetAllocations_RevertsWhenBpsDontSumTo10000() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3000;
        bps[1] = 6000;

        vm.prank(manager);
        vm.expectRevert(Vault.InvalidAllocation.selector);
        v.setTargetAllocations(ids, bps);
    }

    function _deployBoth(Vault v) internal {
        address[] memory pathA = new address[](2);
        pathA[0] = address(usdc);
        pathA[1] = address(tokenA);
        address[] memory pathB = new address[](2);
        pathB[0] = address(usdc);
        pathB[1] = address(tokenB);
        vm.startPrank(manager);
        v.swapUsdcToAsset(0, pathA, 0);
        v.swapUsdcToAsset(1, pathB, 0);
        vm.stopPrank();
    }

    function test_ExecuteRebalance_OverweightSellChangesBalances() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        // After 60/40 deploy through the real pool (fee + minor price impact): A holds
        // ~600k, B holds ~400k.
        assertApproxEqRel(tokenA.balanceOf(address(v)), 600_000, 0.01e18);
        assertApproxEqRel(tokenB.balanceOf(address(v)), 400_000, 0.01e18);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3000;
        bps[1] = 7000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        uint256 aBefore = tokenA.balanceOf(address(v));
        uint256 usdcBefore = usdc.balanceOf(address(v));

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(tokenA);
        sellPath[1] = address(usdc);

        vm.prank(manager);
        v.executeRebalance(0, sellPath, 0);

        assertLt(tokenA.balanceOf(address(v)), aBefore, "overweight A should be sold");
        assertGt(usdc.balanceOf(address(v)), usdcBefore, "sell proceeds should arrive as USDC");
    }

    function test_ExecuteRebalance_UnderweightBuyFromFreeUsdc() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        // Fund free USDC so the underweight buy branch can execute.
        usdc.mint(address(v), 500_000);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 8000;
        bps[1] = 2000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        uint256 aBefore = tokenA.balanceOf(address(v));
        uint256 usdcBefore = usdc.balanceOf(address(v));

        address[] memory buyPath = new address[](2);
        buyPath[0] = address(usdc);
        buyPath[1] = address(tokenA);

        vm.prank(manager);
        v.executeRebalance(0, buyPath, 0);

        assertGt(tokenA.balanceOf(address(v)), aBefore, "underweight A should be bought");
        assertLt(usdc.balanceOf(address(v)), usdcBefore, "buy should consume free USDC");
    }

    function test_ExecuteRebalance_DriftBandIsNoOp() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        // Keep targets at 60/40 — drift is 0, within REBALANCE_DRIFT_BPS.
        uint256 aBefore = tokenA.balanceOf(address(v));
        uint256 bBefore = tokenB.balanceOf(address(v));
        uint256 usdcBefore = usdc.balanceOf(address(v));

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(tokenA);
        sellPath[1] = address(usdc);

        vm.prank(manager);
        v.executeRebalance(0, sellPath, 0);

        assertEq(tokenA.balanceOf(address(v)), aBefore);
        assertEq(tokenB.balanceOf(address(v)), bBefore);
        assertEq(usdc.balanceOf(address(v)), usdcBefore);
    }

    function test_ExecuteRebalance_WindDownSellsDownToSubDriftBandDust() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        // Drop B from targets → 0% wind-down; A takes 100%.
        uint64[] memory ids = new uint64[](1);
        ids[0] = assetA;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps);
        assertEq(v.numAssets(), 2);
        assertEq(v.allocationBpsAt(1), 0);

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(tokenB);
        sellPath[1] = address(usdc);

        vm.prank(manager);
        v.executeRebalance(1, sellPath, 0);

        // The sell amount is sized off the NavCalculation-priced NAV snapshot, while the real pool
        // fills at a slightly different price — so a single pass can leave sub-lot-size
        // dust rather than an exact zero balance. That dust's value is now far under
        // Constants.REBALANCE_DRIFT_BPS of NAV, so the drift band correctly treats a
        // second pass as a no-op and the slot never auto-retires — an accepted tradeoff
        // of driving rebalance sizing off NavCalculation price against a live AMM fill.
        assertLt(tokenB.balanceOf(address(v)), 1000, "wind-down should sell nearly all B");
        assertEq(v.numAssets(), 2, "dust balance keeps the 0% slot from auto-retiring");

        vm.prank(manager);
        v.executeRebalance(1, sellPath, 0);

        assertLt(tokenB.balanceOf(address(v)), 1000, "sub-drift-band dust is left in place");
        assertEq(v.numAssets(), 2, "drift band correctly no-ops on dust below threshold");
    }

    // ── Path B write-off ──────────────────────────────────────────────────────

    function test_WriteOff_RequiresManagerProposeAndSuperAdminConfirm() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        vm.prank(user);
        vm.expectRevert(Vault.NotVaultManager.selector);
        v.proposeWriteOff(assetA);

        vm.prank(manager);
        v.proposeWriteOff(assetA);

        vm.prank(user);
        vm.expectRevert(); // NotSuperAdmin
        zenoIndexVault.confirmWriteOff(0, assetA);

        zenoIndexVault.confirmWriteOff(0, assetA); // superAdmin = address(this) in this test
        assertTrue(v.isWrittenOff(assetA));
    }

    function test_WriteOff_RemovesAssetFromNavAndSlotCount() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint256 navBefore = v.totalNav();

        vm.prank(manager);
        v.proposeWriteOff(assetA);
        zenoIndexVault.confirmWriteOff(0, assetA);

        assertEq(v.numAssets(), 1);
        assertTrue(v.isWrittenOff(assetA));
        // NAV should not increase after write-off (asset's value, if any, leaves NAV).
        uint256 navAfter = v.totalNav();
        assertTrue(navAfter <= navBefore);
    }

    function test_WriteOff_ClearsPendingUsdcForRetiredSlot() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        // Genesis earmarks 60% of seed to A and 40% to B as undeployed pending.
        uint256 pendingA = v.usdcTargetAmountAt(0);
        uint256 pendingB = v.usdcTargetAmountAt(1);
        uint256 pendingBefore = v.totalPendingUsdc();
        assertEq(pendingA, 600_000);
        assertEq(pendingB, 400_000);
        assertEq(pendingBefore, pendingA + pendingB);

        uint256 navBefore = v.totalNav();

        vm.prank(manager);
        v.proposeWriteOff(assetA);
        zenoIndexVault.confirmWriteOff(0, assetA);

        // A's pending must leave totalPendingUsdc; B compacts into slot 0.
        assertEq(v.numAssets(), 1);
        assertEq(v.totalPendingUsdc(), pendingB);
        assertEq(v.usdcTargetAmountAt(0), pendingB);
        assertEq(v.totalNav(), navBefore - pendingA);

        // Remaining pending is still deployable via the surviving slot.
        address[] memory pathB = new address[](2);
        pathB[0] = address(usdc);
        pathB[1] = address(tokenB);
        vm.prank(manager);
        v.swapUsdcToAsset(0, pathB, 0);
        assertEq(v.totalPendingUsdc(), 0);
        assertApproxEqRel(tokenB.balanceOf(address(v)), pendingB, 0.01e18);
    }

    function test_Reactivate_RestoresAssetToZeroBpsSlot() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        vm.prank(manager);
        v.proposeWriteOff(assetA);
        zenoIndexVault.confirmWriteOff(0, assetA);

        vm.prank(manager);
        v.proposeReactivate(assetA);
        zenoIndexVault.confirmReactivate(0, assetA);

        assertFalse(v.isWrittenOff(assetA));
        assertEq(v.numAssets(), 2);
        assertEq(v.allocationBpsAt(1), 0); // reactivated at 0% — manager re-weights separately
    }

    function test_NoSweepFunction_WrittenOffTokensStayInCustody() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint256 balBefore = tokenA.balanceOf(address(v));

        vm.prank(manager);
        v.proposeWriteOff(assetA);
        zenoIndexVault.confirmWriteOff(0, assetA);

        // Balance is untouched by write-off — tokens remain in the vault's custody.
        assertEq(tokenA.balanceOf(address(v)), balBefore);
    }

    // ── PRE_MAINNET_REVIEW.md regression tests ──────────────────────────────────
    // Each test below pins the fix for one Critical/High finding from the pre-mainnet
    // review so the bug cannot silently come back.

    /// @dev Critical #1: swapUsdcToAsset must reject a path that lands on the wrong
    ///      output token, and must be manager/operator-gated (not permissionless).
    function test_SwapUsdcToAsset_RevertsWhenPathEndsOnWrongMint() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        // Slot 0 is assetA (tokenA), but the supplied path routes to tokenB instead.
        address[] memory wrongPath = new address[](2);
        wrongPath[0] = address(usdc);
        wrongPath[1] = address(tokenB);

        vm.prank(manager);
        vm.expectRevert(Vault.PathEnd.selector);
        v.swapUsdcToAsset(0, wrongPath, 0);
    }

    function test_SwapUsdcToAsset_RevertsForNonManager() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(tokenA);

        vm.prank(user);
        vm.expectRevert(Vault.NotVaultManager.selector);
        v.swapUsdcToAsset(0, path, 0);
    }

    /// @dev Critical #2: an underweight rebalance buy must never spend USDC that is
    ///      earmarked as totalPendingUsdc or owed to redeemers in escrow.
    function test_ExecuteRebalance_UnderweightBuyNeverSpendsEscrowedOrPendingUsdc() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        // Put the vault into an active-redeem state so vaultRedeemEscrowTotal > 0, and
        // leave assetB's slot with real pending USDC (never swapped) so totalPendingUsdc
        // stays nonzero too — both must be excluded from the rebalance buy's "free" USDC.
        uint256 depositAmt = 50_000_000;
        vm.startPrank(user);
        usdc.approve(address(v), depositAmt);
        v.deposit(depositAmt, 0);
        uint256 userShares = ShareToken(v.sharesToken()).balanceOf(user);
        v.requestRedeem(userShares);
        vm.stopPrank();

        uint256 pendingBefore = v.totalPendingUsdc();
        uint256 escrowBefore = v.vaultRedeemEscrowTotal();
        assertGt(pendingBefore + escrowBefore, 0, "test setup should leave USDC earmarked");

        // Skew target allocations so assetA is underweight and the buy branch fires.
        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 9000;
        bps[1] = 1000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        address[] memory buyPath = new address[](2);
        buyPath[0] = address(usdc);
        buyPath[1] = address(tokenA);

        vm.prank(manager);
        v.executeRebalance(0, buyPath, 0);

        // The earmarked amounts must be exactly as before — untouched by the buy.
        assertEq(v.totalPendingUsdc(), pendingBefore, "rebalance must not spend pending USDC");
        assertEq(v.vaultRedeemEscrowTotal(), escrowBefore, "rebalance must not spend escrowed USDC");
        assertGe(
            usdc.balanceOf(address(v)),
            pendingBefore + escrowBefore,
            "vault must retain enough USDC to cover pending + escrow"
        );
    }

    function test_ExecuteRebalance_RevertsWhenPathEndsOnWrongToken() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3000;
        bps[1] = 7000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps);

        // Overweight sell of A must end at USDC — this path wrongly ends at tokenB.
        address[] memory badSellPath = new address[](2);
        badSellPath[0] = address(tokenA);
        badSellPath[1] = address(tokenB);

        vm.prank(manager);
        vm.expectRevert(Vault.PathEnd.selector);
        v.executeRebalance(0, badSellPath, 0);
    }

    /// @dev Critical #4: deposit/redeem fee bps must be clamped to Constants' bounds at init.
    function test_CreateVault_RevertsWhenDepositFeeExceedsMax() public {
        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6000;
        bps[1] = 4000;

        ZenoIndexVault.CreateVaultParams memory p = ZenoIndexVault.CreateVaultParams({
            feeRecipient: feeRecipient,
            depositFeeBps: Constants.MAX_DEPOSIT_FEE_BPS + 1,
            redeemFeeBps: 50,
            assetIds: ids,
            allocationBps: bps,
            fundType: 1,
            maxShares: 0,
            name: "Test Vault",
            symbol: "tVLT"
        });

        vm.prank(manager);
        vm.expectRevert(Vault.FeeOutOfBounds.selector);
        zenoIndexVault.createVault(p);
    }

    function test_CreateVault_RevertsWhenRedeemFeeBelowMin() public {
        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6000;
        bps[1] = 4000;

        ZenoIndexVault.CreateVaultParams memory p = ZenoIndexVault.CreateVaultParams({
            feeRecipient: feeRecipient,
            depositFeeBps: 100,
            redeemFeeBps: Constants.MIN_REDEEM_FEE_BPS - 1,
            assetIds: ids,
            allocationBps: bps,
            fundType: 1,
            maxShares: 0,
            name: "Test Vault",
            symbol: "tVLT"
        });

        vm.prank(manager);
        vm.expectRevert(Vault.FeeOutOfBounds.selector);
        zenoIndexVault.createVault(p);
    }

    /// @dev Critical #5: duplicate asset ids must be rejected, both at vault creation and
    ///      when re-targeting allocations, and createAsset must reject a duplicate mint.
    function test_CreateVault_RevertsOnDuplicateAssetIds() public {
        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetA;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;

        ZenoIndexVault.CreateVaultParams memory p = ZenoIndexVault.CreateVaultParams({
            feeRecipient: feeRecipient,
            depositFeeBps: 100,
            redeemFeeBps: 50,
            assetIds: ids,
            allocationBps: bps,
            fundType: 1,
            maxShares: 0,
            name: "Test Vault",
            symbol: "tVLT"
        });

        vm.prank(manager);
        vm.expectRevert(ZenoIndexVault.AlreadyExists.selector);
        zenoIndexVault.createVault(p);
    }

    function test_SetTargetAllocations_RevertsOnDuplicateAssetIds() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetA;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;

        vm.prank(manager);
        vm.expectRevert(Vault.DuplicateAsset.selector);
        v.setTargetAllocations(ids, bps);
    }

    /// @dev "setTargetAllocations still accepts unregistered ids (NAV DOS)": an assetId that
    ///      was never created via ZenoIndexVault.createAsset resolves via getAsset() to
    ///      mint == address(0). Storing it as a slot would permanently brick every NAV read
    ///      (deposit/redeem/rebalance/totalNav) for the vault, since ERC20Minimal(address(0))
    ///      has no code to call. setTargetAllocations must reject it up front.
    function test_SetTargetAllocations_RevertsOnUnregisteredAssetId() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint64 unregisteredAssetId = 999;

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = unregisteredAssetId;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;

        vm.prank(manager);
        vm.expectRevert(Vault.AssetNotRegistered.selector);
        v.setTargetAllocations(ids, bps);
    }

    function test_SetTargetAllocations_RevertsOnInactiveAssetId() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        zenoIndexVault.setAssetActive(assetB, false);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;

        vm.prank(manager);
        vm.expectRevert(Vault.AssetNotActive.selector);
        v.setTargetAllocations(ids, bps);
    }

    function test_CreateAsset_RevertsOnDuplicateMint() public {
        vm.expectRevert(ZenoIndexVault.DuplicateMint.selector);
        zenoIndexVault.createAsset(address(tokenA));
    }

    /// @dev AccessMaster: an operator (granted via AccessMaster.addOperator, read live
    ///      through IAccessMaster) can add and deactivate assets, same as super-admin — the
    ///      role lives entirely in AccessMaster, not in ZenoIndexVault's own storage.
    function test_CreateAsset_OperatorFromAccessMasterCanAddAsset() public {
        address operator = address(0xDEED);
        accessMaster.addOperator(operator);

        MockERC20 tokenC = new MockERC20("Token C", "TKC", 6);
        vm.prank(operator);
        uint64 assetC = zenoIndexVault.createAsset(address(tokenC));

        (,, bool active, bool exists) = zenoIndexVault.getAsset(assetC);
        assertTrue(exists);
        assertTrue(active);
    }

    function test_SetAssetActive_OperatorFromAccessMasterCanDeactivate() public {
        address operator = address(0xDEED);
        accessMaster.addOperator(operator);

        vm.prank(operator);
        zenoIndexVault.setAssetActive(assetA, false);

        (,, bool active,) = zenoIndexVault.getAsset(assetA);
        assertFalse(active);
    }

    function test_CreateAsset_RevertsForAccountNotSuperAdminOrOperator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ZenoIndexVault.NotSuperAdmin.selector);
        zenoIndexVault.createAsset(address(0xC0FFEE));
    }

    function test_CreateAsset_RevokedOperatorLosesAccess() public {
        address operator = address(0xDEED);
        accessMaster.addOperator(operator);
        accessMaster.removeOperator(operator);

        vm.prank(operator);
        vm.expectRevert(ZenoIndexVault.NotSuperAdmin.selector);
        zenoIndexVault.createAsset(address(0xC0FFEE));
    }

    /// @dev ZenoIndexVault.superAdmin()/isOperator() are live passthroughs to AccessMaster —
    ///      a role change on AccessMaster is reflected immediately with no separate sync step.
    function test_SuperAdminAndIsOperator_ReadLiveThroughToAccessMaster() public {
        assertEq(zenoIndexVault.superAdmin(), accessMaster.superAdmin());

        address operator = address(0xDEED);
        assertFalse(zenoIndexVault.isOperator(operator));
        accessMaster.addOperator(operator);
        assertTrue(zenoIndexVault.isOperator(operator));
    }

    /// @dev Critical #6: write-off must be blocked while the slot has a reserved balance
    ///      pinned to an in-flight redeem leg, so slot compaction never desyncs RedeemState.
    function test_ExecuteWriteOff_RevertsWhileAssetIsReservedForActiveRedeem() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        uint256 userShares = ShareToken(v.sharesToken()).balanceOf(address(v)); // genesis shares held by vault itself
        // Give the user real shares to redeem against deployed assets.
        uint256 depositAmt = 100_000_000;
        vm.startPrank(user);
        usdc.approve(address(v), depositAmt);
        v.deposit(depositAmt, 0);
        vm.stopPrank();
        vm.prank(manager);
        v.swapUsdcToAsset(0, _pathUsdcTo(address(tokenA)), 0);

        uint256 redeemShares = ShareToken(v.sharesToken()).balanceOf(user);
        vm.prank(user);
        v.requestRedeem(redeemShares);

        assertGt(v.reservedAt(0), 0, "slot 0 should have a reserved balance from the pending redeem");

        vm.prank(manager);
        v.proposeWriteOff(assetA);

        vm.expectRevert(Vault.AssetReserved.selector);
        zenoIndexVault.confirmWriteOff(0, assetA);

        userShares; // silence unused-var warning from the genesis-shares comment above
    }

    function _pathUsdcTo(address token) internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(usdc);
        path[1] = token;
    }

    /// @dev Critical #6 (full fix): write-off/wind-down of a DIFFERENT, unreserved slot must
    ///      also be blocked while any redeem is active — not only a write-off of the exact
    ///      slot holding the reservation. Here slot 1 (tokenB) never got deployed, so its
    ///      _reservedAssets stays 0 even after requestRedeem (its pro-rata amount rounds to
    ///      0 on undeployed balance), while slot 0 (tokenA) still has an unswapped redeem
    ///      leg — so the redeem as a whole is still active. Writing off slot 1 must still be
    ///      blocked, because _retireSlot would compact slot 0 out from under the in-flight
    ///      RedeemState if numAssets ever shrank past it.
    function test_ExecuteWriteOff_RevertsForUnrelatedSlotWhileAnyRedeemIsActive() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        // Deploy only slot 0 (tokenA); leave slot 1 (tokenB) undeployed so its free balance,
        // and therefore its reservation from requestRedeem, is 0.
        vm.prank(manager);
        v.swapUsdcToAsset(0, _pathUsdcTo(address(tokenA)), 0);

        uint256 depositAmt = 100_000_000;
        vm.startPrank(user);
        usdc.approve(address(v), depositAmt);
        v.deposit(depositAmt, 0);
        uint256 redeemShares = ShareToken(v.sharesToken()).balanceOf(user);
        v.requestRedeem(redeemShares);
        vm.stopPrank();

        assertGt(v.reservedAt(0), 0, "slot 0 (tokenA) should hold a reservation from the redeem");
        assertEq(v.reservedAt(1), 0, "slot 1 (tokenB) never deployed, so it has nothing reserved");
        (bool active,,) = v.getRedeemState(user);
        assertTrue(active, "redeem should still be active (slot 0's leg is unswapped)");
        assertEq(v.activeRedeemCount(), 1);

        vm.prank(manager);
        v.proposeWriteOff(assetB);

        // Old (partial) fix only checked _reservedAssets[slotB] == 0 and would have allowed
        // this through. The full fix blocks on activeRedeemCount instead.
        vm.expectRevert(Vault.AssetReserved.selector);
        zenoIndexVault.confirmWriteOff(0, assetB);
    }

    /// @dev Same loophole via the auto-retire path in executeRebalance's wind-down branch:
    ///      a 0%-target, zero-balance, unreserved slot must NOT be compacted out while a
    ///      different slot's redeem leg is still in flight — it should just skip and leave
    ///      the slot in place instead.
    ///
    ///      Slot 1 (tokenB) is the vault's only funded asset here, so its NavCalculation-priced
    ///      value equals the entire NAV and currentBps rounds to exactly BPS_DENOM — the
    ///      sell-delta math (Vault.sol's executeRebalance) then sizes sellAmount == free
    ///      exactly, with no rounding dust, so it reliably clears the whole balance to 0
    ///      in one call (unlike the multi-asset case in
    ///      test_ExecuteRebalance_WindDownSellsDownToSubDriftBandDust, where dust is
    ///      unavoidable).
    function test_ExecuteRebalance_AutoRetireSkipsWhileAnyRedeemIsActive() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        // Deploy only slot 1 (tokenB); slot 0 (tokenA) stays undeployed so it contributes
        // nothing to NAV and slot 1's value equals the whole NAV.
        vm.prank(manager);
        v.swapUsdcToAsset(1, _pathUsdcTo(address(tokenB)), 0);
        assertGt(tokenB.balanceOf(address(v)), 0);

        // Wind slot 1 down to 0% target (slot 0 takes 100%).
        uint64[] memory ids = new uint64[](1);
        ids[0] = assetA;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps);
        assertEq(v.allocationBpsAt(1), 0);

        // Start a redeem so activeRedeemCount > 0 while slot 1 winds down. Its pro-rata
        // reservation lands mostly on slot 1 (the only funded asset) — swap that leg first
        // so slot 1 ends with zero balance AND zero reservation, satisfying every
        // auto-retire precondition except activeRedeemCount == 0.
        uint256 depositAmt = 100_000_000;
        vm.startPrank(user);
        usdc.approve(address(v), depositAmt);
        v.deposit(depositAmt, 0);
        uint256 redeemShares = ShareToken(v.sharesToken()).balanceOf(user);
        v.requestRedeem(redeemShares);
        address[] memory redeemPathB = new address[](2);
        redeemPathB[0] = address(tokenB);
        redeemPathB[1] = address(usdc);
        v.swapAssetToUsdc(1, redeemPathB, 0);
        vm.stopPrank();
        assertEq(v.reservedAt(1), 0, "slot 1's redeem leg should be fully swapped, reservation cleared");
        assertEq(v.activeRedeemCount(), 1, "slot 0's leg is still unswapped, so the redeem is still active");

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(tokenB);
        sellPath[1] = address(usdc);

        vm.prank(manager);
        v.executeRebalance(1, sellPath, 0);

        assertEq(tokenB.balanceOf(address(v)), 0, "the sell should fully clear slot 1's remaining free balance");
        assertEq(v.numAssets(), 2, "auto-retire must skip while a redeem is active, even at zero balance");
    }

    function test_Constructor_RevertsOnZeroAccessMaster() public {
        vm.expectRevert(ZenoIndexVault.ZeroAddress.selector);
        new ZenoIndexVault(address(usdc), address(vaultImpl), address(0));
    }



    /// @dev Valuation must work with prices set only on NavCalculation.
    function test_Deposit_UsesNavCalculationPrices() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        uint256 beforeNav = v.totalNav();
        uint256 depositAmt = 1_000_000e6;
        vm.startPrank(user);
        usdc.approve(address(v), depositAmt);
        uint256 shares = v.deposit(depositAmt, 0);
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(v.totalNav(), beforeNav);
    }

    /// @dev High: the router allowance must be reset to 0 after every swap, so a router
    ///      that pulls less than the approved amount cannot later be re-drawn on.
    function test_SwapUsdcToAsset_ZeroesRouterAllowanceAfterSwap() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);

        vm.prank(manager);
        v.swapUsdcToAsset(0, _pathUsdcTo(address(tokenA)), 0);

        assertEq(usdc.allowance(address(v), address(router)), 0, "USDC allowance to router must be zeroed after swap");
    }
}
