// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract RegisterRemainingPools is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant MU = 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        UniswapV4Adapter adapter = UniswapV4Adapter(vm.envAddress("ADAPTER_ADDRESS"));

        require(block.chainid == 4663, "Wrong chain");
        require(adapter.admin() == signer, "Signer is not adapter admin");

        bytes32[4] memory ids = [_pairId(USDG, TSLA), _pairId(USDG, META), _pairId(USDG, MU), _pairId(USDG, SPCX)];
        for (uint256 i; i < ids.length; ++i) {
            require(!adapter.poolSet(ids[i]), "Pool already registered");
        }

        vm.startBroadcast(pk);
        adapter.setPool(USDG, TSLA, 3000, 60, address(0));
        adapter.setPool(USDG, META, 3000, 60, address(0));
        adapter.setPool(USDG, MU, 10000, 200, address(0));
        adapter.setPool(USDG, SPCX, 3000, 60, address(0));
        vm.stopBroadcast();

        console2.log("Registered TSLA, META, MU and SPCX pools");
    }

    function _pairId(address a, address b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a < b ? a : b, a < b ? b : a));
    }
}
