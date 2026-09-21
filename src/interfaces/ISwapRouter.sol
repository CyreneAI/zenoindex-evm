// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice DEX-agnostic swap interface. Every swap is expressed as a hop path — path[0] is
///         the input token, path[path.length-1] is the output token, and any tokens in
///         between are intermediate hops (e.g. [USDC, WETH, DOG] for a 2-hop route).
///         No route/path is ever stored on-chain; the caller supplies it fresh each call.
interface ISwapRouter {
    /// @param path Hop path, length >= 2. path[0] = input token, path[last] = output token.
    /// @param amountIn Exact input amount (pulled from `from` via allowance to router)
    /// @param minAmountOut Slippage floor on the final output token
    /// @param from Token source
    /// @param to Token destination
    /// @return amountOut Actual output received by `to`, in path[last]'s units
    function swap(
        address[] calldata path,
        uint256 amountIn,
        uint256 minAmountOut,
        address from,
        address to
    ) external returns (uint256 amountOut);
}
