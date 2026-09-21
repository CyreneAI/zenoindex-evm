// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {Pricing} from "../src/Pricing.sol";
import {Swap_mod} from "../src/Swap_mod.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {ShareToken} from "../src/tokens/ShareToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceOracle} from "../src/mocks/MockPriceOracle.sol";
import {MockSwapRouter} from "../src/mocks/MockSwapRouter.sol";

contract ZenoIndexVaultTest is Test {
    ZenoIndexVault internal zenoIndexVault;
    Vault internal vaultImpl;
    Pricing internal pricing;
    Swap_mod internal swapMod;
    MockERC20 internal usdc;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockPriceOracle internal oracle;
    MockSwapRouter internal router;

    address internal treasury = address(0xA11);
    address internal manager = address(0xB22);
    address internal feeRecipient = address(0xC33);
    address internal user = address(0xD44);

    uint64 internal assetA;
    uint64 internal assetB;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        tokenA = new MockERC20("Token A", "TKA", 6);
        tokenB = new MockERC20("Token B", "TKB", 6);
        oracle = new MockPriceOracle();
        router = new MockSwapRouter();

        vaultImpl = new Vault();
        pricing = new Pricing();
        zenoIndexVault = new ZenoIndexVault(address(usdc), treasury, address(vaultImpl), address(oracle));
        swapMod = new Swap_mod(address(zenoIndexVault));

        zenoIndexVault.setPricingModule(address(pricing));
        zenoIndexVault.setSwapModule(address(swapMod));
        zenoIndexVault.setSwapRouter(address(router));

        router.setRate(address(usdc), address(tokenA), 1, 1);
        router.setRate(address(tokenA), address(usdc), 1, 1);
        router.setRate(address(usdc), address(tokenB), 1, 1);
        router.setRate(address(tokenB), address(usdc), 1, 1);
        usdc.mint(address(router), 1_000_000_000e6);
        tokenA.mint(address(router), 1_000_000_000e6);
        tokenB.mint(address(router), 1_000_000_000e6);

        oracle.setPriceWhole(address(tokenA), 1_000_000);
        oracle.setPriceWhole(address(tokenB), 1_000_000);

        assetA = zenoIndexVault.createAsset(address(tokenA));
        assetB = zenoIndexVault.createAsset(address(tokenB));

        usdc.mint(manager, 10_000_000e6);
        usdc.mint(user, 10_000_000e6);
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

        MockSwapRouter newRouter = new MockSwapRouter();
        newRouter.setRate(address(usdc), address(tokenA), 1, 1);
        tokenA.mint(address(newRouter), 1_000_000e6);

        zenoIndexVault.setSwapRouter(address(newRouter));

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(tokenA);

        // v was created before the router swap, but reads the CURRENT router live —
        // no re-init needed for the new router to take effect.
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
        v.swapUsdcToAsset(0, pathA, 0);
        v.swapUsdcToAsset(1, pathB, 0);
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
        v.swapUsdcToAsset(0, pathA, 0);
        v.swapUsdcToAsset(1, pathB, 0);
    }

    function test_ExecuteRebalance_OverweightSellChangesBalances() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _deployBoth(v);

        // After 60/40 deploy at 1:1 rates: A holds 600k, B holds 400k.
        assertEq(tokenA.balanceOf(address(v)), 600_000);
        assertEq(tokenB.balanceOf(address(v)), 400_000);

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

    function test_ExecuteRebalance_WindDownSellRetiresSlot() public {
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

        assertEq(tokenB.balanceOf(address(v)), 0, "wind-down should sell all B");
        assertEq(v.numAssets(), 1, "zero-balance 0% slot should auto-retire");
        assertEq(v.assetIdAt(0), assetA);
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
        v.swapUsdcToAsset(0, pathB, 0);
        assertEq(v.totalPendingUsdc(), 0);
        assertEq(tokenB.balanceOf(address(v)), pendingB);
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
}
