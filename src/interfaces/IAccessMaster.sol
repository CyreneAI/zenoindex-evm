// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Read surface AccessMaster.sol exposes to any contract that needs to check who
///         holds the admin role, is a registered operator, or where treasury fees go.
interface IAccessMaster {
    function superAdmin() external view returns (address);
    function isOperator(address account) external view returns (bool);
    function treasury() external view returns (address);
}
