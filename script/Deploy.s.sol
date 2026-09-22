// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {Pricing} from "../src/Pricing.sol";
import {SwapExecutor} from "../src/SwapExecutor.sol";

/// @notice Production deploy for the clone-factory ZenoIndexVault.
///         Deploys Vault impl + Pricing + ZenoIndexVault + SwapExecutor, then wires
///         an existing stablecoin (USDC or USDG), price oracle, and swap router.
///
/// Required env:
///   PRIVATE_KEY   — deployer key (hex, with or without 0x)
///   STABLECOIN    — deposit token address (USDC or USDG)
///   PRICE_ORACLE  — IPriceOracle address
///   SWAP_ROUTER   — ISwapRouter address (e.g. UniswapV4Adapter)
///
/// Optional env:
///   TREASURY      — fee treasury (defaults to deployer)
///   ASSET_0..ASSET_4 — optional ERC-20 mints to register via createAsset
///
/// Robinhood Chain Testnet (chainId 46630):
///   1. Fund deployer with test ETH: https://faucet.testnet.chain.robinhood.com
///   2. cp .env.example .env  # set PRIVATE_KEY, RH_RPC_URL, STABLECOIN, PRICE_ORACLE, SWAP_ROUTER
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
        address priceOracle = vm.envAddress("PRICE_ORACLE");
        address swapRouter = vm.envAddress("SWAP_ROUTER");

        require(stablecoin != address(0), "STABLECOIN=0");
        require(priceOracle != address(0), "PRICE_ORACLE=0");
        require(swapRouter != address(0), "SWAP_ROUTER=0");

        console2.log("Chain id:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);
        console2.log("Stablecoin (USDC/USDG):", stablecoin);
        console2.log("Price oracle:", priceOracle);
        console2.log("Swap router:", swapRouter);
        console2.log("Deployer ETH balance:", deployer.balance);

        vm.startBroadcast(pk);

        Vault vaultImpl = new Vault();
        Pricing pricing = new Pricing();

        ZenoIndexVault zenoIndexVault = new ZenoIndexVault(stablecoin, treasury, address(vaultImpl), priceOracle);
        SwapExecutor swapExecutor = new SwapExecutor(address(zenoIndexVault));

        zenoIndexVault.setPricingModule(address(pricing));
        zenoIndexVault.setSwapModule(address(swapExecutor));
        zenoIndexVault.setSwapRouter(swapRouter);

        _registerOptionalAssets(zenoIndexVault);

        vm.stopBroadcast();

        console2.log("--- deployed ---");
        console2.log("ZenoIndexVault (factory):", address(zenoIndexVault));
        console2.log("Vault (impl):            ", address(vaultImpl));
        console2.log("Pricing:                 ", address(pricing));
        console2.log("SwapExecutor:            ", address(swapExecutor));
        console2.log("superAdmin:", zenoIndexVault.superAdmin());
        console2.log("usdcToken: ", zenoIndexVault.usdcToken());
    }

    /// @dev Registers ASSET_0 .. ASSET_4 when set (address(0) / unset is skipped).
    function _registerOptionalAssets(ZenoIndexVault zenoIndexVault) internal {
        address[5] memory mints = [
            vm.envOr("ASSET_0", address(0)),
            vm.envOr("ASSET_1", address(0)),
            vm.envOr("ASSET_2", address(0)),
            vm.envOr("ASSET_3", address(0)),
            vm.envOr("ASSET_4", address(0))
        ];

        for (uint256 i = 0; i < mints.length; i++) {
            if (mints[i] == address(0)) continue;
            uint64 assetId = zenoIndexVault.createAsset(mints[i]);
            console2.log("Registered assetId:", assetId);
            console2.log("  mint:", mints[i]);
        }
    }
}
