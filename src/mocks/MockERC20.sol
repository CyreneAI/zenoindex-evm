// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20Minimal} from "../tokens/ERC20Minimal.sol";

contract MockERC20 is ERC20Minimal {
    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20Minimal(name_, symbol_, decimals_)
    {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
