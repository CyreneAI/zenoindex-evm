// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {AccessMaster} from "../src/AccessMaster.sol";

/// @notice Production deploy for the clone-factory ZenoIndexVault.
///         Deploys Vault impl + AccessMaster + ZenoIndexVault, then wires an existing
///         stablecoin (USDC or USDG). NAV/valuation and swap execution (formerly
///         NavCalculation.sol / SwapExecutor.sol) now live inside ZenoIndexVault.sol
///         itself. `createVault` reverts until the router is set and every basket asset
///         has a price, so no vault can go live half-configured.
///
/// Post-deploy (super-admin), before the first vault:
///   1. UniswapV4Adapter.setAuthorizedCaller(zenoIndexVault, true)   — adapter admin
///   2. zenoIndexVault.setSwapRouter(adapter)
///   3. zenoIndexVault.setPriceWhole(asset, usdcPerWholeToken) for any asset not priced here
///   4. zenoIndexVault.setVaultCreator(manager, true) for each account allowed to create vaults
///   Prices go stale after `maxPriceAge` (default 1 day) — keep a keeper refreshing them.
///
/// Required env:
///   PRIVATE_KEY   — deployer key (hex, with or without 0x)
///   STABLECOIN    — deposit token address (USDC or USDG)
///
/// Optional env:
///   TREASURY      — fee treasury (defaults to deployer)
///   ASSET_0..ASSET_4 — optional ERC-20 mints to register via createAsset
///   ASSET_0_PRICE..ASSET_4_PRICE — optional USDC (6-dec) per whole token, set via setPriceWhole
///
/// Robinhood Chain Testnet (chainId 46630):
///   1. Fund deployer with test ETH: https://faucet.testnet.chain.robinhood.com
///   2. cp .env.example .env  # set PRIVATE_KEY, RH_RPC_URL, STABLECOIN
///   3. set -a && source .env && set +a
///   4. forge script script/Deploy.s.sol:Deploy \
///        --rpc-url $RH_RPC_URL --broadcast --chain-id 46630 -vvvv
///
/// Mainnet (chainId 4663): same with RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com
/// and --chain-id 4663 (needs real ETH for gas).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", deployer);

        address stablecoin = vm.envAddress("STABLECOIN");

        require(stablecoin != address(0), "STABLECOIN=0");

        console2.log("Chain id:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);
        console2.log("Stablecoin (USDC/USDG):", stablecoin);
        console2.log("Deployer ETH balance:", deployer.balance);

        vm.startBroadcast(pk);

        Vault vaultImpl = new Vault();
        AccessMaster accessMaster = new AccessMaster(deployer, treasury);

        ZenoIndexVault zenoIndexVault =
            new ZenoIndexVault(stablecoin, address(vaultImpl), address(accessMaster));

        _registerOptionalAssets(zenoIndexVault);

        vm.stopBroadcast();

        console2.log("--- deployed ---");
        console2.log("ZenoIndexVault (factory):", address(zenoIndexVault));
        console2.log("Vault (impl):            ", address(vaultImpl));
        console2.log("AccessMaster:            ", address(accessMaster));
        console2.log("superAdmin:", zenoIndexVault.superAdmin());
        console2.log("treasury:  ", zenoIndexVault.treasury());
        console2.log("usdcToken: ", zenoIndexVault.usdcToken());
    }

    /// @dev Registers ASSET_0 .. ASSET_4 when set (address(0) / unset is skipped), pricing
    ///      each one first when ASSET_i_PRICE is set.
    function _registerOptionalAssets(ZenoIndexVault zenoIndexVault) internal {
        address[5] memory mints = [
            vm.envOr("ASSET_0", address(0)),
            vm.envOr("ASSET_1", address(0)),
            vm.envOr("ASSET_2", address(0)),
            vm.envOr("ASSET_3", address(0)),
            vm.envOr("ASSET_4", address(0))
        ];
        uint256[5] memory prices = [
            vm.envOr("ASSET_0_PRICE", uint256(0)),
            vm.envOr("ASSET_1_PRICE", uint256(0)),
            vm.envOr("ASSET_2_PRICE", uint256(0)),
            vm.envOr("ASSET_3_PRICE", uint256(0)),
            vm.envOr("ASSET_4_PRICE", uint256(0))
        ];

        for (uint256 i = 0; i < mints.length; i++) {
            if (mints[i] == address(0)) continue;
            if (prices[i] != 0) zenoIndexVault.setPriceWhole(mints[i], prices[i]);
            uint64 assetId = zenoIndexVault.createAsset(mints[i]);
            console2.log("Registered assetId:", assetId);
            console2.log("  mint:", mints[i]);
        }
    }
}
