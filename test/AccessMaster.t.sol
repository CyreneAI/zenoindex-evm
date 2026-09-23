// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessMaster} from "../src/AccessMaster.sol";

contract AccessMasterTest is Test {
    AccessMaster internal accessMaster;

    address internal admin = address(this);
    address internal newAdmin = address(0xA11CE);
    address internal operator = address(0xB0B);
    address internal stranger = address(0xBAD);
    address internal treasury0 = address(0x7EA5);
    address internal treasury1 = address(0x7EA1);

    function setUp() public {
        accessMaster = new AccessMaster(admin, treasury0);
    }

    function test_Constructor_SetsInitialSuperAdminAndTreasury() public view {
        assertEq(accessMaster.superAdmin(), admin);
        assertEq(accessMaster.treasury(), treasury0);
        assertTrue(accessMaster.hasRole(accessMaster.ADMIN_ROLE(), admin));
        assertEq(accessMaster.ADMIN_ROLE(), accessMaster.DEFAULT_ADMIN_ROLE());
    }

    function test_Constructor_RevertsOnZeroSuperAdmin() public {
        vm.expectRevert(AccessMaster.ZeroAddress.selector);
        new AccessMaster(address(0), treasury0);
    }

    function test_Constructor_RevertsOnZeroTreasury() public {
        vm.expectRevert(AccessMaster.ZeroAddress.selector);
        new AccessMaster(admin, address(0));
    }

    // ── Admin transfer — two-step: propose, then the new admin accepts ──

    function _transferAdmin(address to) internal {
        accessMaster.setSuperAdmin(to);
        vm.prank(to);
        accessMaster.acceptSuperAdmin();
    }

    function test_SetSuperAdmin_OnlyProposesUntilAccepted() public {
        vm.expectEmit(true, true, false, false);
        emit AccessMaster.SuperAdminTransferStarted(admin, newAdmin);
        accessMaster.setSuperAdmin(newAdmin);

        assertEq(accessMaster.pendingSuperAdmin(), newAdmin);
        assertEq(accessMaster.superAdmin(), admin, "nothing moves before accept");
        assertTrue(accessMaster.hasRole(accessMaster.ADMIN_ROLE(), admin));
        assertFalse(accessMaster.hasRole(accessMaster.ADMIN_ROLE(), newAdmin));
    }

    function test_AcceptSuperAdmin_TransfersRoleAndSuperAdmin() public {
        accessMaster.setSuperAdmin(newAdmin);

        vm.expectEmit(true, true, false, false);
        emit AccessMaster.SuperAdminTransferred(admin, newAdmin);
        vm.prank(newAdmin);
        accessMaster.acceptSuperAdmin();

        assertEq(accessMaster.superAdmin(), newAdmin);
        assertEq(accessMaster.pendingSuperAdmin(), address(0));
        assertTrue(accessMaster.hasRole(accessMaster.ADMIN_ROLE(), newAdmin));
        assertFalse(accessMaster.hasRole(accessMaster.ADMIN_ROLE(), admin), "old admin should lose the role");

        vm.prank(newAdmin);
        accessMaster.setTreasury(treasury1);
        assertEq(accessMaster.treasury(), treasury1);
    }

    function test_AcceptSuperAdmin_RevertsForNonPending() public {
        accessMaster.setSuperAdmin(newAdmin);
        vm.prank(stranger);
        vm.expectRevert(AccessMaster.NotPendingSuperAdmin.selector);
        accessMaster.acceptSuperAdmin();
    }

    function test_SetSuperAdmin_TypoIsRecoverableByReproposing() public {
        accessMaster.setSuperAdmin(stranger); // wrong address
        accessMaster.setSuperAdmin(newAdmin); // overwrite before anyone accepts

        vm.prank(stranger);
        vm.expectRevert(AccessMaster.NotPendingSuperAdmin.selector);
        accessMaster.acceptSuperAdmin();

        vm.prank(newAdmin);
        accessMaster.acceptSuperAdmin();
        assertEq(accessMaster.superAdmin(), newAdmin);
    }

    /// @dev Review #4: ADMIN_ROLE can't be moved outside setSuperAdmin/accept, so the role
    ///      holder and `superAdmin()` never split.
    function test_AdminRole_CannotBeGrantedRevokedOrRenouncedDirectly() public {
        bytes32 adminRole = accessMaster.ADMIN_ROLE();

        vm.expectRevert(AccessMaster.AdminRoleManagedBySetSuperAdmin.selector);
        accessMaster.grantRole(adminRole, newAdmin);

        vm.expectRevert(AccessMaster.AdminRoleManagedBySetSuperAdmin.selector);
        accessMaster.revokeRole(adminRole, admin);

        vm.expectRevert(AccessMaster.AdminRoleManagedBySetSuperAdmin.selector);
        accessMaster.renounceRole(adminRole, admin);

        assertEq(accessMaster.superAdmin(), admin);
        assertTrue(accessMaster.hasRole(adminRole, admin));
    }

    function test_SetSuperAdmin_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        accessMaster.setSuperAdmin(newAdmin);
    }

    function test_SetSuperAdmin_RevertsOnZeroAddress() public {
        vm.expectRevert(AccessMaster.ZeroAddress.selector);
        accessMaster.setSuperAdmin(address(0));
    }

    function test_SetSuperAdmin_OldAdminCanNoLongerActAfterTransfer() public {
        _transferAdmin(newAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0))
        );
        accessMaster.setSuperAdmin(stranger);
    }

    // ── Operators — addOperator / removeOperator (thin, named wrappers) ──

    function test_AddRemoveOperator_TogglesOperatorRole() public {
        assertFalse(accessMaster.isOperator(operator));

        vm.expectEmit(true, false, false, false);
        emit AccessMaster.OperatorAdded(operator);
        accessMaster.addOperator(operator);
        assertTrue(accessMaster.isOperator(operator));
        assertTrue(accessMaster.hasRole(accessMaster.OPERATOR_ROLE(), operator));

        vm.expectEmit(true, false, false, false);
        emit AccessMaster.OperatorRemoved(operator);
        accessMaster.removeOperator(operator);
        assertFalse(accessMaster.isOperator(operator));
    }

    function test_AddOperator_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        accessMaster.addOperator(operator);
    }

    function test_AddOperator_RevertsOnZeroAddress() public {
        vm.expectRevert(AccessMaster.ZeroAddress.selector);
        accessMaster.addOperator(address(0));
    }

    function test_RemoveOperator_RevertsForNonAdmin() public {
        accessMaster.addOperator(operator);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        accessMaster.removeOperator(operator);
    }

    function test_RemoveOperator_NoopWhenAlreadyNotOperator() public {
        assertFalse(accessMaster.isOperator(operator));
        accessMaster.removeOperator(operator);
        assertFalse(accessMaster.isOperator(operator));
    }

    // ── Operators — OZ's own grantRole / revokeRole(OPERATOR_ROLE, ...) still work too ──

    function test_GrantRevokeRole_TogglesOperatorRole() public {
        bytes32 operatorRole = accessMaster.OPERATOR_ROLE();
        assertFalse(accessMaster.isOperator(operator));

        accessMaster.grantRole(operatorRole, operator);
        assertTrue(accessMaster.isOperator(operator));
        assertTrue(accessMaster.hasRole(operatorRole, operator));

        accessMaster.revokeRole(operatorRole, operator);
        assertFalse(accessMaster.isOperator(operator));
    }

    function test_GrantRole_RevertsForNonAdmin() public {
        bytes32 operatorRole = accessMaster.OPERATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        accessMaster.grantRole(operatorRole, operator);
    }

    function test_SuperAdminTransfer_NewAdminCanThenGrantOperatorRole() public {
        bytes32 operatorRole = accessMaster.OPERATOR_ROLE();

        _transferAdmin(newAdmin);

        vm.prank(newAdmin);
        accessMaster.grantRole(operatorRole, operator);
        assertTrue(accessMaster.isOperator(operator));

        // Old admin has lost the role and can no longer grant/revoke.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0))
        );
        accessMaster.revokeRole(operatorRole, operator);
    }

    // ── Treasury ──

    function test_SetTreasury_UpdatesAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit AccessMaster.TreasuryUpdated(treasury1);
        accessMaster.setTreasury(treasury1);
        assertEq(accessMaster.treasury(), treasury1);
    }

    function test_SetTreasury_RevertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        accessMaster.setTreasury(treasury1);
    }

    function test_SetTreasury_RevertsOnZeroAddress() public {
        vm.expectRevert(AccessMaster.ZeroAddress.selector);
        accessMaster.setTreasury(address(0));
    }
}
