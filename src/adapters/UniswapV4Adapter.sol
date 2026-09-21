// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {ERC20Minimal} from "../tokens/ERC20Minimal.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice ISwapRouter adapter that routes ZenoIndexVault swaps through a Uniswap V4 PoolManager,
///         chaining a caller-supplied hop path (e.g. [USDC, WETH, DOG]) across consecutive
///         per-pair pools. Each hop is exact-input, single-pool, admin-registered.
contract UniswapV4Adapter is ISwapRouter, IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public admin;

    /// @dev keccak256(sorted tokenA, tokenB) => registered pool for that adjacent pair.
    mapping(bytes32 => PoolKey) public pools;
    mapping(bytes32 => bool) public poolSet;

    struct HopData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address from; // only meaningful for hop 0 (pulls from the true caller)
    }

    struct SwapData {
        address[] path;
        uint256 amountIn;
        uint256 minAmountOut;
        address from;
        address to;
    }

    event PoolRegistered(address indexed tokenA, address indexed tokenB, uint24 fee, int24 tickSpacing, address hooks);
    event AdminChanged(address indexed newAdmin);

    error OnlyAdmin();
    error OnlyPoolManager();
    error PoolNotSet();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error ZeroAddress();
    error InvalidPath();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(address poolManager_, address admin_) {
        if (poolManager_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        admin = admin_;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    /// @notice Registers the V4 pool used to swap between `tokenA` and `tokenB` directly
    ///         (one adjacent hop in a caller-supplied path).
    function setPool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing, address hooks)
        external
        onlyAdmin
    {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        (address currency0, address currency1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        bytes32 pairId = _pairId(tokenA, tokenB);
        pools[pairId] = key;
        poolSet[pairId] = true;

        emit PoolRegistered(tokenA, tokenB, fee, tickSpacing, hooks);
    }

    function swap(
        address[] calldata path,
        uint256 amountIn,
        uint256 minAmountOut,
        address from,
        address to
    ) external returns (uint256 amountOut) {
        if (path.length < 2) revert InvalidPath();
        for (uint256 i = 0; i < path.length - 1; i++) {
            if (!poolSet[_pairId(path[i], path[i + 1])]) revert PoolNotSet();
        }

        require(ERC20Minimal(path[0]).transferFrom(from, address(this), amountIn), "IN");

        bytes memory result = poolManager.unlock(abi.encode(SwapData({
            path: path,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            from: from,
            to: to
        })));
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        SwapData memory data = abi.decode(rawData, (SwapData));

        uint256 currentAmount = data.amountIn;
        for (uint256 i = 0; i < data.path.length - 1; i++) {
            address hopIn = data.path[i];
            address hopOut = data.path[i + 1];
            PoolKey memory key = pools[_pairId(hopIn, hopOut)];
            bool zeroForOne = Currency.unwrap(key.currency0) == hopIn;

            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(currentAmount),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );

            (Currency inCurrency, Currency outCurrency) =
                zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
            int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
            int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
            uint256 hopAmountIn = uint256(uint128(-inDelta));
            uint256 hopAmountOut = uint256(uint128(outDelta));

            poolManager.sync(inCurrency);
            require(ERC20Minimal(Currency.unwrap(inCurrency)).transfer(address(poolManager), hopAmountIn), "PAY");
            poolManager.settle();

            // Intermediate hops keep proceeds in this adapter to feed the next hop;
            // the final hop pays the true recipient.
            bool isFinalHop = (i == data.path.length - 2);
            poolManager.take(outCurrency, isFinalHop ? data.to : address(this), hopAmountOut);

            if (hopAmountIn < currentAmount) {
                // Partial fill on a non-final hop would desync accounting; only supported
                // cleanly on the first hop where a refund target (`from`) is well-defined.
                require(i == 0, "PARTIAL_MID_HOP");
                require(
                    ERC20Minimal(Currency.unwrap(inCurrency)).transfer(data.from, currentAmount - hopAmountIn), "REFUND"
                );
            }

            currentAmount = hopAmountOut;
        }

        if (currentAmount < data.minAmountOut) revert SlippageExceeded(currentAmount, data.minAmountOut);

        return abi.encode(currentAmount);
    }

    function _pairId(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(a, b));
    }
}
