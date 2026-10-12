// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract CheckUsdgnNvdaPool is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    function run() external view {
        IPoolManager manager = IPoolManager(MANAGER);
        (address c0, address c1) = USDG < NVDA
            ? (USDG, NVDA)
            : (NVDA, USDG);

        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];

        for (uint256 i; i < fees.length; ++i) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: fees[i],
                tickSpacing: spacings[i],
                hooks: IHooks(address(0))
            });

            PoolId id = key.toId();
            (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) =
                manager.getSlot0(id);
            uint128 liquidity = manager.getLiquidity(id);

            console2.log("Fee:", fees[i]);
            console2.log("Tick spacing:", uint256(uint24(spacings[i])));
            console2.log("Pool ID:");
            console2.logBytes32(PoolId.unwrap(id));
            console2.log("sqrtPriceX96:", uint256(sqrtPriceX96));
            console2.log("Tick:", int256(tick));
            console2.log("LP fee:", lpFee);
            console2.log("Liquidity:", uint256(liquidity));
        }
    }
}
