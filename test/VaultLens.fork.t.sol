// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {VaultLens} from "../src/lens/VaultLens.sol";

/// @notice Runs the lens against the live Robinhood Chain mainnet deployment (read-only).
///         Skipped when RH_RPC_URL is not set. Run with:
///         forge test --match-path test/VaultLens.fork.t.sol -vv
contract VaultLensForkTest is Test {
    address internal constant FACTORY = 0xD00ABbC1d1555a173c5081b2204579b057B05378;
    VaultLens internal lens;
    address internal zdi;
    address internal vaultImpl;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        zdi = vm.parseAddress("0x9b50d625747d52191a0e7238a63629cfeadf3491");
        vaultImpl = vm.parseAddress("0xe76f73be98f7002fc8b68466c5a8780d993f0115");
        lens = new VaultLens();
    }

    function test_Fork_ZdiIsCloneOfDeployedImplementation() public {
        vm.skip(!forked);
        assertTrue(ZenoIndexVault(FACTORY).isVaultClone(zdi));
        bytes memory expected =
            abi.encodePacked(hex"363d3d373d3d3d363d73", vaultImpl, hex"5af43d82803e903d91602b57fd5bf3");
        assertEq(keccak256(zdi.code), keccak256(expected), "ERC-1167 clone of the recorded implementation");
    }

    function test_Fork_ZdiLensMatchesTotalNav() public {
        vm.skip(!forked);
        console2.log("block", block.number);
        _checkVault(zdi);
    }

    /// @dev Every vault the factory has created, including demo vaults added after ZDI.
    function test_Fork_AllFactoryVaultsLensMatchesTotalNav() public {
        vm.skip(!forked);
        uint64 n = ZenoIndexVault(FACTORY).totalVaults();
        console2.log("block", block.number);
        console2.log("factory vaults", uint256(n));
        for (uint64 id = 0; id < n; id++) {
            address vault = ZenoIndexVault(FACTORY).vaultClones(id);
            console2.log("=== vault id", uint256(id), vault);
            _checkVault(vault);
        }
    }

    function _checkVault(address vault) internal view {
        VaultLens.VaultView memory lv = lens.getVault(vault);
        assertEq(lv.factory, FACTORY);
        _log(lv);

        try Vault(vault).totalNav() returns (uint256 nav) {
            assertTrue(lv.navComplete, "vault NAV readable => lens complete");
            assertEq(lv.totalNavUsdc, nav);
        } catch {
            // totalNav() reverts only on a stale/missing price for a held asset.
            assertFalse(lv.navComplete, "vault NAV reverted => lens incomplete");
        }

        uint256 sum = lv.unallocatedUsdc + lv.pendingUsdc;
        for (uint256 i = 0; i < lv.assets.length; i++) {
            sum += lv.assets[i].valueUsdc;
        }
        assertEq(sum, lv.totalNavUsdc, "parts sum to NAV");
        assertEq(lv.aumUsdc, lv.totalNavUsdc + lv.redeemEscrowUsdc + lv.reservedValueUsdc, "AUM = NAV + owed to redeemers");
    }

    function _log(VaultLens.VaultView memory lv) internal pure {
        console2.log("totalNavUsdc", lv.totalNavUsdc);
        console2.log("navComplete", lv.navComplete);
        console2.log("aumUsdc", lv.aumUsdc);
        console2.log("pendingUsdc", lv.pendingUsdc);
        console2.log("unallocatedUsdc", lv.unallocatedUsdc);
        console2.log("redeemEscrowUsdc", lv.redeemEscrowUsdc);
        console2.log("reservedValueUsdc", lv.reservedValueUsdc);
        console2.log("totalShares", lv.totalShares);
        console2.log("navPerShare", lv.navPerShare);
        for (uint256 i = 0; i < lv.assets.length; i++) {
            VaultLens.AssetView memory a = lv.assets[i];
            console2.log("asset", uint256(a.assetId), a.mint);
            console2.log("  value / currentBps / targetBps", a.valueUsdc, uint256(a.currentBps), uint256(a.targetBps));
            console2.log("  priceStatus (0 peg,1 fresh,2 stale,3 missing)", uint256(a.priceStatus));
        }
        console2.log("writtenOff count", lv.writtenOff.length);
    }
}
