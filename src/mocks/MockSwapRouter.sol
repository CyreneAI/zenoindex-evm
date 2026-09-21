// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {ERC20Minimal} from "../tokens/ERC20Minimal.sol";

/// @notice Local/test swap router with fixed per-pair rates, chained across a caller-supplied
///         hop path. Fund it with output tokens (of every intermediate + final hop) before swaps.
contract MockSwapRouter is ISwapRouter {
    struct Rate {
        uint256 rateIn;
        uint256 rateOut;
    }

    error InvalidPath();
    error NoRate(address tokenIn, address tokenOut);

    mapping(address => mapping(address => Rate)) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 rateIn, uint256 rateOut) external {
        rates[tokenIn][tokenOut] = Rate({rateIn: rateIn, rateOut: rateOut});
    }

    function swap(
        address[] calldata path,
        uint256 amountIn,
        uint256 minAmountOut,
        address from,
        address to
    ) external returns (uint256 amountOut) {
        if (path.length < 2) revert InvalidPath();

        require(ERC20Minimal(path[0]).transferFrom(from, address(this), amountIn), "IN");

        uint256 currentAmount = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address hopIn = path[i];
            address hopOut = path[i + 1];
            Rate memory r = rates[hopIn][hopOut];
            if (r.rateIn == 0 || r.rateOut == 0) revert NoRate(hopIn, hopOut);
            currentAmount = (currentAmount * r.rateOut) / r.rateIn;
        }

        amountOut = currentAmount;
        require(amountOut >= minAmountOut, "SLIPPAGE");
        require(ERC20Minimal(path[path.length - 1]).transfer(to, amountOut), "OUT");
    }
}
