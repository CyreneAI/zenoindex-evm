// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {Vault} from "../src/Vault.sol";
import {AccessMaster} from "../src/AccessMaster.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {ShareToken} from "../src/tokens/ShareToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {VaultLens} from "../src/lens/VaultLens.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract VaultLensTest is Test {
    ZenoIndexVault internal zenoIndexVault;
    Vault internal vaultImpl;
    AccessMaster internal accessMaster;
    FeeEscrow internal feeEscrow;
    MockERC20 internal usdc;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal liquidityRouter;
    UniswapV4Adapter internal router;
    VaultLens internal lens;

    address internal treasury = address(0xA11);
    address internal manager = address(0xB22);
    address internal feeRecipient = address(0xC33);
    address internal user = address(0xD44);
    address internal user2 = address(0xD55);
    address internal dexAdmin = address(0xDEC0);
    address internal lp = address(0x11);

    uint64 internal assetA;
    uint64 internal assetB;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant POOL_TICK_SPACING = 10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant BASELINE = 1_000_000_000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tokenA = new MockERC20("Token A", "TKA", 6);
        tokenB = new MockERC20("Token B", "TKB", 6);
        poolManager = new PoolManager(address(this));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        router = new UniswapV4Adapter(address(poolManager), dexAdmin);

        vaultImpl = new Vault();
        accessMaster = new AccessMaster(address(this), treasury);
        zenoIndexVault = new ZenoIndexVault(address(usdc), address(vaultImpl), address(accessMaster));
        feeEscrow = new FeeEscrow(address(zenoIndexVault), address(accessMaster));
        zenoIndexVault.setFeeEscrow(address(feeEscrow));

        zenoIndexVault.setSwapRouter(address(router));
        vm.prank(dexAdmin);
        router.setAuthorizedCaller(address(zenoIndexVault), true);
        zenoIndexVault.setVaultCreator(manager, true);

        _initPoolAndSeed(address(usdc), address(tokenA));
        _initPoolAndSeed(address(usdc), address(tokenB));

        zenoIndexVault.setPriceWhole(address(tokenA), 1_000_000);
        zenoIndexVault.setPriceWhole(address(tokenB), 1_000_000);

        assetA = zenoIndexVault.createAsset(address(tokenA));
        assetB = zenoIndexVault.createAsset(address(tokenB));

        usdc.mint(manager, 10_000_000e6);
        lens = new VaultLens();
    }

    // ── Empty / pending-only ─────────────────────────────────────────────────

    function test_EmptyVault_BeforeGenesis() public {
        Vault v = _vaultAB();
        VaultLens.VaultView memory lv = lens.getVault(address(v));

        assertEq(lv.totalNavUsdc, 0);
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertTrue(lv.navComplete);
        assertEq(lv.navPerShare, 0);
        assertEq(lv.assets.length, 2);
        assertEq(lv.assets[0].assetId, assetA);
        assertEq(lv.assets[0].targetBps, 6000);
        assertEq(lv.assets[1].targetBps, 4000);
        assertEq(lv.assets[0].currentBps, 0);
        assertEq(lv.writtenOff.length, 0);
        assertEq(lv.factory, address(zenoIndexVault));
    }

    function test_PendingDeposits_CountInNavAsPending() public {
        Vault v = _vaultAB();
        _genesis(v);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertEq(lv.totalNavUsdc, Constants.GENESIS_SEED_USDC);
        assertEq(lv.pendingUsdc, Constants.GENESIS_SEED_USDC);
        assertEq(lv.pendingBps, 10_000);
        assertEq(lv.assets[0].pendingUsdc, 600_000);
        assertEq(lv.assets[1].pendingUsdc, 400_000);
        assertEq(lv.assets[0].valueUsdc, 0);
        assertEq(lv.navPerShare, BASELINE, "nav/share starts at the genesis baseline");
        _assertPartsSum(lv);
    }

    // ── Deployed basket ───────────────────────────────────────────────────────

    function test_DeployedBasket_MatchesTotalNavAndWeights() public {
        Vault v = _vaultAB();
        _genesis(v);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertTrue(lv.navComplete);
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertEq(lv.aumUsdc, lv.totalNavUsdc, "nothing owed to redeemers, so AUM == NAV");
        assertEq(lv.pendingUsdc, 0);
        assertApproxEqAbs(lv.assets[0].currentBps, 6000, 100);
        assertApproxEqAbs(lv.assets[1].currentBps, 4000, 100);
        assertEq(lv.assets[0].balance, tokenA.balanceOf(address(v)));
        assertEq(uint8(lv.assets[0].priceStatus), uint8(VaultLens.PriceStatus.Fresh));
        assertEq(lv.navPerShare, (lv.totalNavUsdc * Constants.PRICE_SCALE) / v.totalShares());
        _assertPartsSum(lv);
    }

    // ── Stale / missing prices ────────────────────────────────────────────────

    function test_StalePrice_LensDoesNotRevertAndFlagsIncomplete() public {
        Vault v = _vaultAB();
        _genesis(v);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);
        uint256 navBefore = v.totalNav();

        vm.warp(block.timestamp + zenoIndexVault.maxPriceAge() + 1);

        vm.expectRevert(abi.encodeWithSelector(ZenoIndexVault.StalePrice.selector, address(tokenA)));
        v.totalNav();

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertFalse(lv.navComplete);
        assertEq(lv.totalNavUsdc, navBefore, "valued at the last stored price");
        assertEq(uint8(lv.assets[0].priceStatus), uint8(VaultLens.PriceStatus.Stale));
        assertEq(uint8(lv.assets[1].priceStatus), uint8(VaultLens.PriceStatus.Stale));

        (uint256 nav, bool complete) = lens.navOf(address(v));
        assertEq(nav, navBefore);
        assertFalse(complete);
    }

    /// @dev sumNav skips quoting an asset the vault holds none of, so a stale price there
    ///      does not break totalNav — the lens must not report it as incomplete either.
    function test_StalePrice_OnUnheldAssetKeepsNavComplete() public {
        Vault v = _vaultAB();
        _genesis(v); // everything still pending; no A or B held

        vm.warp(block.timestamp + zenoIndexVault.maxPriceAge() + 1);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertTrue(lv.navComplete);
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertEq(uint8(lv.assets[0].priceStatus), uint8(VaultLens.PriceStatus.Stale));
    }

    function test_MissingPrice_ValuedAtZeroAndFlagsIncomplete() public {
        Vault v = _vaultAB();
        _genesis(v);
        _deployBoth(v);
        vm.mockCall(
            address(zenoIndexVault),
            abi.encodeWithSignature("priceDen(address)", address(tokenA)),
            abi.encode(uint256(0))
        );

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertFalse(lv.navComplete);
        assertEq(uint8(lv.assets[0].priceStatus), uint8(VaultLens.PriceStatus.Missing));
        assertEq(lv.assets[0].valueUsdc, 0);
        assertGt(lv.assets[0].freeAmount, 0);
    }

    // ── Redeems ───────────────────────────────────────────────────────────────

    function test_ActiveRedeem_ReservedAndEscrowExcludedFromNav() public {
        Vault v = _vaultAB();
        _genesis(v);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);
        _depositAs(v, user2, 50_000e6); // left pending, so the redeem also carves escrow

        uint256 shares = ShareToken(v.sharesToken()).balanceOf(user) / 2;
        vm.prank(user);
        v.requestRedeem(shares);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertTrue(lv.navComplete);
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertGt(lv.redeemEscrowUsdc, 0);
        assertEq(lv.redeemEscrowUsdc, v.vaultRedeemEscrowTotal());
        for (uint8 i = 0; i < 2; i++) {
            VaultLens.AssetView memory a = lv.assets[i];
            assertGt(a.reserved, 0);
            assertEq(a.reserved, v.reservedAt(i));
            assertEq(a.freeAmount, a.balance - a.reserved);
        }
        assertGt(lv.reservedValueUsdc, 0);
        assertEq(lv.aumUsdc, lv.totalNavUsdc + lv.redeemEscrowUsdc + lv.reservedValueUsdc);
        assertGt(lv.aumUsdc, lv.totalNavUsdc, "AUM includes what is owed to redeemers; NAV does not");
        _assertPartsSum(lv);
    }

    // ── USDC handling ─────────────────────────────────────────────────────────

    function test_UsdcSlot_ExcludesPendingAndEscrow() public {
        uint64 usdcAsset = zenoIndexVault.createAsset(address(usdc));
        Vault v = _vault2(usdcAsset, assetA, 5000, 5000);
        _genesis(v);
        _depositAs(v, user, 100e6); // half stays USDC, half pending for A

        uint256 shares = ShareToken(v.sharesToken()).balanceOf(user) / 2;
        vm.prank(user);
        v.requestRedeem(shares);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertEq(lv.unallocatedUsdc, 0, "free USDC belongs to the USDC slot");
        VaultLens.AssetView memory u = lv.assets[0];
        assertEq(uint8(u.priceStatus), uint8(VaultLens.PriceStatus.Peg));
        assertEq(u.freeAmount, u.balance - lv.pendingUsdc - lv.redeemEscrowUsdc);
        _assertPartsSum(lv);
    }

    function test_UsdcNotASlot_SaleProceedsShowAsUnallocated() public {
        Vault v = _vaultAB();
        _genesis(v);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA;
        ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3000;
        bps[1] = 7000;
        vm.startPrank(manager);
        v.setTargetAllocations(ids, bps);
        v.executeRebalance(0, _path(address(tokenA), address(usdc)), 0);
        vm.stopPrank();

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertGt(lv.unallocatedUsdc, 0);
        assertEq(lv.unallocatedUsdc, usdc.balanceOf(address(v)) - lv.pendingUsdc - lv.redeemEscrowUsdc);
        assertGt(lv.unallocatedBps, 0);
        assertEq(lv.assets[0].targetBps, 3000);
        _assertPartsSum(lv);
    }

    function test_AllUsdcVault_IsOneHundredPercentUsdc() public {
        uint64 usdcAsset = zenoIndexVault.createAsset(address(usdc));
        uint64[] memory ids = new uint64[](1);
        ids[0] = usdcAsset;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        Vault v = _createVault(ids, bps);
        _genesis(v);
        _depositAs(v, user, 1_000e6);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertEq(lv.totalNavUsdc, usdc.balanceOf(address(v)));
        assertEq(lv.pendingUsdc, 0, "a USDC slot is never pending");
        assertEq(lv.assets[0].currentBps, 10_000);
        _assertPartsSum(lv);
    }

    // ── Write-off ─────────────────────────────────────────────────────────────

    function test_WrittenOffAsset_ListedSeparatelyAndExcludedFromNav() public {
        Vault v = _vaultAB();
        _genesis(v);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);
        uint256 heldA = tokenA.balanceOf(address(v));

        vm.prank(manager);
        v.proposeWriteOff(assetA);
        zenoIndexVault.confirmWriteOff(v.vaultId(), assetA);

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertEq(lv.totalNavUsdc, v.totalNav());
        assertEq(lv.assets.length, 1);
        assertEq(lv.assets[0].assetId, assetB);
        assertEq(lv.writtenOff.length, 1);
        assertEq(lv.writtenOff[0].assetId, assetA);
        assertEq(lv.writtenOff[0].balance, heldA);
        assertEq(lv.writtenOff[0].valueUsdc, heldA, "priced at $1");
        _assertPartsSum(lv);
    }

    // ── Batch + fuzz ──────────────────────────────────────────────────────────

    function test_GetVaults_ReturnsEachVault() public {
        Vault v1 = _vaultAB();
        Vault v2 = _vaultAB();
        _genesis(v1);

        address[] memory vaults = new address[](2);
        vaults[0] = address(v1);
        vaults[1] = address(v2);
        VaultLens.VaultView[] memory out = lens.getVaults(vaults);
        assertEq(out.length, 2);
        assertEq(out[0].totalNavUsdc, v1.totalNav());
        assertEq(out[1].totalNavUsdc, 0);
    }

    /// @dev With fresh prices the lens must equal Vault.totalNav() exactly.
    function testFuzz_LensMatchesTotalNav(uint256 depositAmt, uint256 redeemBps, bool deploy, uint256 secondDeposit)
        public
    {
        depositAmt = bound(depositAmt, 1e6, 1e11);
        redeemBps = bound(redeemBps, 0, 10_000);
        secondDeposit = bound(secondDeposit, 0, 1e10);

        Vault v = _vaultAB();
        _genesis(v);
        _depositAs(v, user, depositAmt);
        if (deploy) _deployBoth(v);
        if (secondDeposit > 0) _depositAs(v, user2, secondDeposit);

        uint256 shares = (ShareToken(v.sharesToken()).balanceOf(user) * redeemBps) / 10_000;
        if (shares > 0) {
            vm.prank(user);
            try v.requestRedeem(shares) {} catch {}
        }

        VaultLens.VaultView memory lv = lens.getVault(address(v));
        assertTrue(lv.navComplete);
        assertEq(lv.totalNavUsdc, v.totalNav());
        _assertPartsSum(lv);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Slot values + unallocated + pending add up to total NAV exactly; weights in
    ///      bps round down, so they sum to at most 10_000 and lose < 1 bp per row.
    function _assertPartsSum(VaultLens.VaultView memory lv) internal pure {
        uint256 sum = lv.unallocatedUsdc + lv.pendingUsdc;
        uint256 bpsSum = uint256(lv.unallocatedBps) + lv.pendingBps;
        for (uint256 i = 0; i < lv.assets.length; i++) {
            sum += lv.assets[i].valueUsdc;
            bpsSum += lv.assets[i].currentBps;
        }
        assertEq(sum, lv.totalNavUsdc, "parts sum to NAV");
        if (lv.totalNavUsdc > 0) {
            assertLe(bpsSum, 10_000);
            assertGe(bpsSum + lv.assets.length + 2, 10_000);
        }
    }

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

    function _vaultAB() internal returns (Vault) {
        return _vault2(assetA, assetB, 6000, 4000);
    }

    function _vault2(uint64 id0, uint64 id1, uint16 bps0, uint16 bps1) internal returns (Vault) {
        uint64[] memory ids = new uint64[](2);
        ids[0] = id0;
        ids[1] = id1;
        uint16[] memory bps = new uint16[](2);
        bps[0] = bps0;
        bps[1] = bps1;
        return _createVault(ids, bps);
    }

    function _createVault(uint64[] memory ids, uint16[] memory bps) internal returns (Vault v) {
        ZenoIndexVault.CreateVaultParams memory p = ZenoIndexVault.CreateVaultParams({
            feeRecipient: feeRecipient,
            depositFeeBps: 0,
            redeemFeeBps: 50,
            assetIds: ids,
            allocationBps: bps,
            fundType: 1,
            maxShares: 0,
            name: "Lens Vault",
            symbol: "LENS"
        });
        vm.prank(manager);
        v = Vault(zenoIndexVault.vaultClones(zenoIndexVault.createVault(p)));
    }

    function _genesis(Vault v) internal {
        vm.startPrank(manager);
        usdc.approve(address(v), Constants.GENESIS_SEED_USDC);
        v.genesisDeposit(BASELINE);
        vm.stopPrank();
    }

    function _depositAs(Vault v, address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        v.deposit(amt, 0);
        vm.stopPrank();
    }

    /// @dev Swaps every slot's pending USDC into its asset (slots 0 = A, 1 = B).
    function _deployBoth(Vault v) internal {
        vm.startPrank(manager);
        v.swapUsdcToAsset(0, _path(address(usdc), address(tokenA)), 0);
        v.swapUsdcToAsset(1, _path(address(usdc), address(tokenB)), 0);
        vm.stopPrank();
    }

    function _path(address from, address to) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }
}
