// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract CheckRegisteredPools is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ADAPTER = 0x1CD3F47e7137761e4c1066273893fbE778BB2Dd7;

    address[5] tokens = [
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d,
        0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35,
        0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD,
        0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa
    ];

    string[5] names = ["NVDA", "TSLA", "META", "MU", "SPCX"];

    function run() external view {
        UniswapV4Adapter adapter = UniswapV4Adapter(ADAPTER);

        for (uint256 i; i < tokens.length; ++i) {
            address a = USDG < tokens[i] ? USDG : tokens[i];
            address b = USDG < tokens[i] ? tokens[i] : USDG;
            bytes32 id = keccak256(abi.encodePacked(a, b));

            console2.log(names[i]);
            console2.logBytes32(id);

            bool registered = adapter.poolSet(id);
            console2.log("Registered:", registered);

            if (!registered) continue;

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = adapter.pools(id);

            console2.log("Currency0:", Currency.unwrap(currency0));
            console2.log("Currency1:", Currency.unwrap(currency1));
            console2.log("Fee:", fee);
            console2.log("Tick spacing:", int256(tickSpacing));
            console2.log("Hooks:", address(hooks));
        }
    }
}
