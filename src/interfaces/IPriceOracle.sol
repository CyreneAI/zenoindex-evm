// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Injectable price adapter (Pyth / DEX spot stand-in). Returns USDC 6-decimal value.
interface IPriceOracle {
    /// @param token Asset token address
    /// @param amount Raw token amount (token decimals)
    /// @return usdcValue Value in USDC 6-decimal base units
    function quoteUsdc(address token, uint256 amount) external view returns (uint256 usdcValue);
}
