
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";

contract DeployAndConfigureUniswapV4Adapter is Script {
   address constant FACTORY = 0xD00ABbC1d1555a173c5081b2204579b057B05378;
   address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
   address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
   address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

   function run() external {
       uint256 pk = vm.envUint("PRIVATE_KEY");
       address admin = vm.addr(pk);
       ZenoIndexVault factory = ZenoIndexVault(FACTORY);

       require(block.chainid == 4663, "Wrong chain");
       require(factory.superAdmin() == admin, "Wrong super-admin");
       require(factory.router() == address(0), "Router already configured");
       require(factory.usdcToken() == USDG, "Unexpected stablecoin");

       bytes32 pairId = keccak256(
           abi.encodePacked(
               USDG < NVDA ? USDG : NVDA,
               USDG < NVDA ? NVDA : USDG
           )
       );

       vm.startBroadcast(pk);

       UniswapV4Adapter adapter = new UniswapV4Adapter(POOL_MANAGER, admin);
       adapter.setAuthorizedCaller(FACTORY, true);
       adapter.setPool(USDG, NVDA, 100, 1, address(0));
       factory.setSwapRouter(address(adapter));

       vm.stopBroadcast();

       console2.log("Adapter deployed:", address(adapter));
       console2.log("Factory configured:", FACTORY);
       console2.log("USDG/NVDA pair ID:");
       console2.logBytes32(pairId);
   }
}
