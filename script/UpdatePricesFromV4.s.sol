// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

interface IPriceFactory {
    function accessMaster() external view returns (address);
    function usdcToken() external view returns (address);
    function router() external view returns (address);
    function maxPriceChangeBps() external view returns (uint16);
    function priceNum(address) external view returns (uint256);
    function priceDen(address) external view returns (uint256);
    function setPrice(address token, uint256 usdcOut, uint256 tokenIn) external;
}

interface IPriceAccessMaster {
    function superAdmin() external view returns (address);
}

interface IPriceAdapter {
    function poolSet(bytes32 pairId) external view returns (bool);
    function pools(bytes32 pairId)
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks);
}

contract UpdatePricesFromV4 is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPriceFactory factory = IPriceFactory(vm.envAddress("FACTORY_ADDRESS"));
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address[5] internal tokens = [
        0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, // SPCX
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d, // TSLA
        0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, // MU
        0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, // META
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC // NVDA
    ];

    string[5] internal names = ["SPCX", "TSLA", "MU", "META", "NVDA"];
    uint24[5] internal fees = [uint24(3000), 3000, 10000, 3000, 100];
    int24[5] internal spacings = [int24(60), 60, 200, 60, 1];

    error WrongChain();
    error WrongAdmin();
    error WrongBaseToken();
    error MissingRouter();
    error PoolNotRegistered(address token);
    error PoolKeyMismatch(address token);
    error PoolUninitialized(address token);
    error NoLiquidity(address token);
    error InvalidPrice(address token);
    error PriceChangeExceedsGuard(address token);

    function run() external {
        require(block.chainid == 4663, "Wrong chain");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);

        if (IPriceAccessMaster(factory.accessMaster()).superAdmin() != signer) {
            revert WrongAdmin();
        }
        if (factory.usdcToken() != USDG) revert WrongBaseToken();
        if (factory.router() == address(0)) revert MissingRouter();

        IPriceAdapter adapter = IPriceAdapter(factory.router());
        IPoolManager manager = IPoolManager(MANAGER);

        uint256[5] memory newPrices;
        uint256[5] memory denominators;

        // Read and validate all five prices before attempting any setter call.
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            (address c0, address c1) = USDG < token ? (USDG, token) : (token, USDG);

            bytes32 pairId = keccak256(abi.encodePacked(c0, c1));
            if (!adapter.poolSet(pairId)) revert PoolNotRegistered(token);

            (Currency stored0, Currency stored1, uint24 storedFee, int24 storedSpacing, IHooks storedHooks) =
                adapter.pools(pairId);

            if (
                Currency.unwrap(stored0) != c0 || Currency.unwrap(stored1) != c1 || storedFee != fees[i]
                    || storedSpacing != spacings[i] || address(storedHooks) != address(0)
            ) {
                revert PoolKeyMismatch(token);
            }

            PoolKey memory key = PoolKey({
                currency0: stored0, currency1: stored1, fee: storedFee, tickSpacing: storedSpacing, hooks: storedHooks
            });

            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(poolId);
            uint128 liquidity = manager.getLiquidity(poolId);

            if (sqrtPriceX96 == 0) revert PoolUninitialized(token);
            if (liquidity == 0) revert NoLiquidity(token);
            if (lpFee == 0) revert PoolUninitialized(token);

            uint256 scale = 10 ** uint256(_decimals(token));
            uint256 q96 = FixedPoint96.Q96;
            uint256 sqrt = uint256(sqrtPriceX96);
            uint256 ratioScale = 1e18;
            uint256 ratio;
            uint256 price;

            // Preserve precision before squaring the Q96 price ratio.
            if (c0 == token) {
                ratio = FullMath.mulDiv(sqrt, ratioScale, q96);
            } else {
                ratio = FullMath.mulDiv(q96, ratioScale, sqrt);
            }

            price = FullMath.mulDiv(ratio, ratio, ratioScale);
            if (scale != ratioScale) {
                price = FullMath.mulDiv(price, scale, ratioScale);
            }

            if (price == 0) revert InvalidPrice(token);

            newPrices[i] = price;
            denominators[i] = scale;

            console2.log("Asset:", names[i]);
            console2.log("Pool ID:");
            console2.logBytes32(PoolId.unwrap(poolId));
            console2.log("sqrtPriceX96:", uint256(sqrtPriceX96));
            console2.log("Tick:", int256(_tick(manager, poolId)));
            console2.log("Liquidity:", uint256(liquidity));
            console2.log("LP fee:", lpFee);
            console2.log("Calculated USDG units per whole token:", price);
            console2.log("Existing price numerator:", factory.priceNum(token));
            console2.log("Existing price denominator:", factory.priceDen(token));
        }

        // Preflight every price against the factory's existing change guard.
        // Complete all checks before making any setter call.
        uint256 bound = factory.maxPriceChangeBps();

        for (uint256 i; i < tokens.length; ++i) {
            uint256 oldNum = factory.priceNum(tokens[i]);
            uint256 oldDen = factory.priceDen(tokens[i]);

            if (bound != 0 && oldDen != 0) {
                uint256 bps = 10_000;

                uint256 upper = FullMath.mulDiv(oldNum, bps + bound, bps);
                uint256 upperRem = mulmod(oldNum, bps + bound, bps);

                uint256 lower = FullMath.mulDiv(oldNum, bps - bound, bps);
                uint256 lowerRem = mulmod(oldNum, bps - bound, bps);

                uint256 q = FullMath.mulDiv(newPrices[i], oldDen, denominators[i]);
                uint256 r = mulmod(newPrices[i], oldDen, denominators[i]);

                bool tooHigh = q > upper;
                if (q == upper) {
                    if (upperRem == 0) {
                        tooHigh = r != 0;
                    } else {
                        uint256 threshold = FullMath.mulDiv(denominators[i], upperRem, bps);
                        tooHigh = r > threshold;
                    }
                }

                bool tooLow = q < lower;
                if (q == lower && lowerRem != 0) {
                    uint256 threshold = FullMath.mulDiv(denominators[i], lowerRem, bps);
                    uint256 thresholdRem = mulmod(denominators[i], lowerRem, bps);
                    tooLow = r < threshold || (r == threshold && thresholdRem != 0);
                }

                if (tooHigh || tooLow) {
                    revert PriceChangeExceedsGuard(tokens[i]);
                }
            }

            console2.log("Preflight passed for:", names[i]);
        }

        // Foundry simulates this by default. Transactions are only broadcast
        // when forge script is explicitly run with --broadcast.
        vm.startBroadcast(pk);
        for (uint256 i; i < tokens.length; ++i) {
            factory.setPrice(tokens[i], newPrices[i], denominators[i]);
        }
        vm.stopBroadcast();
    }

    function _decimals(address token) internal view returns (uint8 value) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, "Token decimals unavailable");
        value = abi.decode(data, (uint8));
    }

    function _tick(IPoolManager manager, PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }
}
