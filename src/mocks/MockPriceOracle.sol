// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ERC20Minimal} from "../tokens/ERC20Minimal.sol";

/// @notice `priceUsdcPerUnit` = USDC (6 dec) value of 1 raw token unit × 1e18 scale helper:
///         usdcValue = amount * priceNum / priceDen
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public priceNum; // USDC out
    mapping(address => uint256) public priceDen; // token in

    function setPrice(address token, uint256 usdcOut, uint256 tokenIn) external {
        priceNum[token] = usdcOut;
        priceDen[token] = tokenIn;
    }

    /// @dev Convenience: set USD price for 1 whole token (accounting for decimals).
    ///      e.g. token 6 dec at $2 → setPriceWhole(token, 2_000_000)
    function setPriceWhole(address token, uint256 usdcPerWholeToken) external {
        uint8 dec = ERC20Minimal(token).decimals();
        priceNum[token] = usdcPerWholeToken;
        priceDen[token] = 10 ** uint256(dec);
    }

    function quoteUsdc(address token, uint256 amount) external view returns (uint256) {
        uint256 den = priceDen[token];
        require(den > 0, "NO_PRICE");
        return (amount * priceNum[token]) / den;
    }
}
