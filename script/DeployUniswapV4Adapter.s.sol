// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract DeployUniswapV4Adapter is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address poolManager =
        0x8366a39CC670B4001A1121B8F6A443A643e40951;

        console2.log("Chain id:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Deployer ETH balance:", deployer.balance);
        console2.log("PoolManager:", poolManager);

        vm.startBroadcast(pk);

        UniswapV4Adapter adapter =
            new UniswapV4Adapter(poolManager, deployer);

        vm.stopBroadcast();

        console2.log("UniswapV4Adapter:", address(adapter));
        console2.log("Admin:", adapter.admin());
        console2.log("PoolManager:", address(adapter.poolManager()));
    }
}
