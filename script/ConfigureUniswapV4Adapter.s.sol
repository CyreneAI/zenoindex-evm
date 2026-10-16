// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";

contract ConfigureUniswapV4Adapter is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    uint24 constant POOL_FEE = 100;
    int24 constant TICK_SPACING = 1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address adapterAddress = vm.envAddress("ADAPTER_ADDRESS");

        UniswapV4Adapter adapter = UniswapV4Adapter(adapterAddress);
        ZenoIndexVault factory = ZenoIndexVault(factoryAddress);

        require(block.chainid == 4663, "Wrong chain");
        require(factoryAddress != address(0), "Factory is zero");
        require(adapterAddress.code.length > 0, "Adapter not deployed");
        require(adapter.admin() == admin, "Signer is not adapter admin");
        require(address(adapter.poolManager()) == POOL_MANAGER, "Wrong PoolManager");
        require(factory.superAdmin() == admin, "Signer is not factory super-admin");
        require(factory.router() == address(0), "Factory router already configured");
        require(factory.usdcToken() == USDG, "Unexpected stablecoin");

        require(!adapter.isAuthorizedCaller(factoryAddress), "Factory already authorized");

        vm.startBroadcast(pk);
        adapter.setAuthorizedCaller(factoryAddress, true);
        factory.setSwapRouter(adapterAddress);
        vm.stopBroadcast();

        console2.log("Configured adapter:", adapterAddress);
        console2.log("Configured factory:", factoryAddress);
    }
}
