// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20Minimal} from "./ERC20Minimal.sol";

/// @notice Vault-controlled share ERC-20 (Token-2022 share mint stand-in).
contract ShareToken is ERC20Minimal {
    address public immutable vault;

    modifier onlyVault() {
        require(msg.sender == vault, "ONLY_VAULT");
        _;
    }

    constructor(string memory name_, string memory symbol_, address vault_)
        ERC20Minimal(name_, symbol_, 6)
    {
        vault = vault_;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
