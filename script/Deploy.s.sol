// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {Pricing} from "../src/Pricing.sol";
import {Swap_mod} from "../src/Swap_mod.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceOracle} from "../src/mocks/MockPriceOracle.sol";
import {MockSwapRouter} from "../src/mocks/MockSwapRouter.sol";

/// @notice Mock-stack deploy for the clone-factory ZenoIndexVault (tokens + router + oracle +
///         Pricing/Swap_mod singletons + ZenoIndexVault factory + Vault implementation).
///
/// Required env:
///   PRIVATE_KEY   — deployer key (hex, with or without 0x)
///
/// Optional env:
///   TREASURY      — fee treasury (defaults to deployer)
///
/// Robinhood Chain Testnet (chainId 46630):
///   1. Fund deployer with test ETH: https://faucet.testnet.chain.robinhood.com
///   2. cp .env.example .env  # set PRIVATE_KEY + RH_RPC_URL
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

        console2.log("Chain id:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);
        console2.log("Deployer ETH balance:", deployer.balance);

        vm.startBroadcast(pk);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 6);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 6);

        MockPriceOracle oracle = new MockPriceOracle();
        MockSwapRouter router = new MockSwapRouter();

        oracle.setPriceWhole(address(weth), 1_000_000);
        oracle.setPriceWhole(address(tokenA), 1_000_000);
        oracle.setPriceWhole(address(tokenB), 1_000_000);

        router.setRate(address(usdc), address(tokenA), 1, 1);
        router.setRate(address(tokenA), address(usdc), 1, 1);
        router.setRate(address(usdc), address(tokenB), 1, 1);
        router.setRate(address(tokenB), address(usdc), 1, 1);
        router.setRate(address(usdc), address(weth), 1e6, 1e18);
        router.setRate(address(weth), address(usdc), 1e18, 1e6);

        usdc.mint(address(router), 1_000_000_000e6);
        weth.mint(address(router), 1_000_000e18);
        tokenA.mint(address(router), 1_000_000_000e6);
        tokenB.mint(address(router), 1_000_000_000e6);

        usdc.mint(deployer, 1_000_000e6);

        Vault vaultImpl = new Vault();
        Pricing pricing = new Pricing();

        ZenoIndexVault zenoIndexVault = new ZenoIndexVault(address(usdc), treasury, address(vaultImpl), address(oracle));
        Swap_mod swapMod = new Swap_mod(address(zenoIndexVault));

        zenoIndexVault.setPricingModule(address(pricing));
        zenoIndexVault.setSwapModule(address(swapMod));
        zenoIndexVault.setSwapRouter(address(router));

        uint64 assetA = zenoIndexVault.createAsset(address(tokenA));
        uint64 assetB = zenoIndexVault.createAsset(address(tokenB));

        vm.stopBroadcast();

        console2.log("--- deployed ---");
        console2.log("ZenoIndexVault (factory): ", address(zenoIndexVault));
        console2.log("Vault (impl):     ", address(vaultImpl));
        console2.log("Pricing:          ", address(pricing));
        console2.log("Swap_mod:         ", address(swapMod));
        console2.log("USDC:             ", address(usdc));
        console2.log("WETH:             ", address(weth));
        console2.log("TokenA:           ", address(tokenA));
        console2.log("TokenB:           ", address(tokenB));
        console2.log("MockSwapRouter:   ", address(router));
        console2.log("MockPriceOracle:  ", address(oracle));
        console2.log("assetA id:        ", assetA);
        console2.log("assetB id:        ", assetB);
        console2.log("superAdmin:       ", zenoIndexVault.superAdmin());
    }
}
