// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IZenoIndexVault} from "./interfaces/IZenoIndexVault.sol";
import {ERC20Minimal} from "./tokens/ERC20Minimal.sol";

/// @notice Singleton NAV/valuation module — the only place vaults get USD (USDC 6-decimal)
///         values. Holds a self-contained per-token price table (no external price feed).
///         Called cross-contract by every Vault.sol clone; vaults never price assets themselves.
contract NavCalculation {
    /// @dev priceUsdcPerUnit helpers: usdcValue = amount * priceNum / priceDen
    mapping(address => uint256) public priceNum; // USDC out (6 dec)
    mapping(address => uint256) public priceDen; // token in (raw units)

    address public admin;

    error NoPrice();
    error OnlyAdmin();
    error ZeroAddress();

    event AdminChanged(address indexed newAdmin);
    event PriceSet(address indexed token, uint256 usdcOut, uint256 tokenIn);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    /// @notice Sets raw price: `usdcOut` USDC (6 dec) for `tokenIn` raw token units.
    function setPrice(address token, uint256 usdcOut, uint256 tokenIn) external onlyAdmin {
        if (token == address(0) || tokenIn == 0) revert ZeroAddress();
        priceNum[token] = usdcOut;
        priceDen[token] = tokenIn;
        emit PriceSet(token, usdcOut, tokenIn);
    }

    /// @dev Convenience: USD price for 1 whole token (accounts for decimals).
    ///      e.g. token 6 dec at $2 → setPriceWhole(token, 2_000_000)
    function setPriceWhole(address token, uint256 usdcPerWholeToken) external onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        uint8 dec = ERC20Minimal(token).decimals();
        priceNum[token] = usdcPerWholeToken;
        priceDen[token] = 10 ** uint256(dec);
        emit PriceSet(token, usdcPerWholeToken, 10 ** uint256(dec));
    }

    /// @notice Values `amount` of `token` in USDC 6-decimal units.
    ///         USDC/USDG (the factory deposit token) is always 1:1; other tokens use the
    ///         price table maintained on this contract.
    function valueUsdc(address zenoIndexVaultAddr, address token, uint256 amount)
        external
        view
        returns (uint256)
    {
        address usdc = IZenoIndexVault(zenoIndexVaultAddr).usdcToken();
        if (token == usdc) return amount;
        return _quote(token, amount);
    }

    /// @notice Sums the USD (USDC 6-decimal) value of `vaultClone`'s free (non-reserved)
    ///         balances across `assetIds`.
    /// @param zenoIndexVaultAddr The ZenoIndexVault root (asset registry + usdcToken)
    /// @param vaultClone The Vault clone whose balances are valued
    /// @param assetIds Current asset slot ids (active + winding-down; never written-off)
    /// @param reservedAmounts Per-asset reserved amounts, same order as `assetIds`
    /// @param excludeFromUsdcLeg Amount to subtract from the raw USDC balance before valuing
    function sumNav(
        address zenoIndexVaultAddr,
        address vaultClone,
        uint64[] calldata assetIds,
        uint256[] calldata reservedAmounts,
        uint256 excludeFromUsdcLeg
    ) external view returns (uint256 total) {
        address usdc = IZenoIndexVault(zenoIndexVaultAddr).usdcToken();
        uint256 n = assetIds.length;
        require(reservedAmounts.length == n, "LEN");

        for (uint256 i = 0; i < n; i++) {
            (, address mint,,) = IZenoIndexVault(zenoIndexVaultAddr).getAsset(assetIds[i]);
            uint256 bal = ERC20Minimal(mint).balanceOf(vaultClone);
            uint256 free = bal > reservedAmounts[i] ? bal - reservedAmounts[i] : 0;

            if (mint == usdc) {
                free = free > excludeFromUsdcLeg ? free - excludeFromUsdcLeg : 0;
                total += free; // $1 peg
            } else {
                if (free == 0) continue;
                total += _quote(mint, free);
            }
        }
    }

    function _quote(address token, uint256 amount) internal view returns (uint256) {
        uint256 den = priceDen[token];
        if (den == 0) revert NoPrice();
        return (amount * priceNum[token]) / den;
    }
}
