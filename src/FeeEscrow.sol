// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessMaster} from "./interfaces/IAccessMaster.sol";

interface IFeeEscrowFactory {
    function isVaultClone(address vault) external view returns (bool);
}

interface IFeeEscrowVault {
    function vaultManager() external view returns (address);
}

/// @notice Shared accounting and claims for platform and vault-manager fees.
/// @dev Only registered vault clones can account fees. The vault must transfer
///      the corresponding tokens to this contract before calling accountFee.
contract FeeEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable accessMaster;

    // Shared across every vault created by the same manager.
    mapping(address manager => mapping(address token => uint256 amount)) public managerClaimable;

    // Central platform accounting, separated by token.
    mapping(address token => uint256 amount) public platformClaimable;

    // Total accrued liabilities per token. Used to protect accounted balances.
    mapping(address token => uint256 amount) public totalClaimable;

    enum FeeType {
        Deposit,
        Redemption,
        Trading
    }

    event FeeAccounted(
        address indexed vault,
        address indexed manager,
        address indexed token,
        FeeType feeType,
        uint256 totalFee,
        uint256 platformFee,
        uint256 managerFee
    );

    event ManagerFeeClaimed(address indexed manager, address indexed token, address indexed recipient, uint256 amount);

    event PlatformFeeClaimed(address indexed token, address indexed recipient, uint256 amount);

    error ZeroAddress();
    error Unauthorized();
    error ZeroAmount();
    error NotRegisteredVault();
    error NoClaimableFees();
    error InsufficientEscrowBalance();

    constructor(address factory_, address accessMaster_) {
        if (factory_ == address(0) || accessMaster_ == address(0)) {
            revert ZeroAddress();
        }

        factory = factory_;
        accessMaster = accessMaster_;
    }

    /// @notice Accounts a fee already transferred into this escrow by a vault.
    /// @param token Token transferred to this escrow.
    /// @param platformFee Company/platform portion calculated by VaultMath.
    /// @param managerFee Manager portion calculated by VaultMath.
    /// @param feeType Origin of the fee.
    function accountFee(address token, uint256 platformFee, uint256 managerFee, FeeType feeType) external {
        if (!IFeeEscrowFactory(factory).isVaultClone(msg.sender)) {
            revert NotRegisteredVault();
        }
        if (token == address(0)) revert ZeroAddress();
        if (platformFee + managerFee == 0) revert ZeroAmount();

        address manager = IFeeEscrowVault(msg.sender).vaultManager();

        uint256 amount = platformFee + managerFee;
        uint256 newTotalClaimable = totalClaimable[token] + amount;

        // Ensure the escrow actually holds enough tokens to cover all
        // previously accrued liabilities plus this newly accounted fee.
        if (IERC20(token).balanceOf(address(this)) < newTotalClaimable) {
            revert InsufficientEscrowBalance();
        }

        platformClaimable[token] += platformFee;
        managerClaimable[manager][token] += managerFee;
        totalClaimable[token] = newTotalClaimable;

        emit FeeAccounted(msg.sender, manager, token, feeType, amount, platformFee, managerFee);
    }

    /// @notice Claims the caller's accumulated fees across all their vaults.
    function claimManagerFees(address token, address recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert ZeroAddress();

        amount = managerClaimable[msg.sender][token];
        if (amount == 0) revert NoClaimableFees();

        managerClaimable[msg.sender][token] = 0;
        totalClaimable[token] -= amount;

        IERC20(token).safeTransfer(recipient, amount);

        emit ManagerFeeClaimed(msg.sender, token, recipient, amount);
    }

    /// @notice Only the currently configured platform treasury can claim.
    function claimPlatformFees(address token) external nonReentrant returns (uint256 amount) {
        address recipient = IAccessMaster(accessMaster).treasury();
        if (msg.sender != recipient) revert Unauthorized();

        amount = platformClaimable[token];
        if (amount == 0) revert NoClaimableFees();

        platformClaimable[token] = 0;
        totalClaimable[token] -= amount;

        IERC20(token).safeTransfer(recipient, amount);

        emit PlatformFeeClaimed(token, recipient, amount);
    }
}
