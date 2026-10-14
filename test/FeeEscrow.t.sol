// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {AccessMaster} from "../src/AccessMaster.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract FeeEscrowFactoryMock {
    mapping(address => bool) public isVaultClone;

    function setVault(address vault, bool allowed) external {
        isVaultClone[vault] = allowed;
    }
}

contract FeeEscrowVaultMock {
    address public vaultManager;

    constructor(address manager_) {
        vaultManager = manager_;
    }
}

contract FeeEscrowTest is Test {
    FeeEscrow internal escrow;
    FeeEscrowFactoryMock internal factory;
    AccessMaster internal accessMaster;
    MockERC20 internal token;

    address internal treasury = address(0xA11);
    address internal managerA = address(0xB22);
    address internal managerB = address(0xC33);
    address internal recipient = address(0xD44);
    address internal vaultA;
    address internal vaultB;
    address internal outsider = address(0xBAD);

    function setUp() public {
        factory = new FeeEscrowFactoryMock();
        accessMaster = new AccessMaster(address(this), treasury);
        token = new MockERC20("USD Coin", "USDC", 6);
        escrow = new FeeEscrow(address(factory), address(accessMaster));

        vaultA = address(new FeeEscrowVaultMock(managerA));
        vaultB = address(new FeeEscrowVaultMock(managerA));
        factory.setVault(vaultA, true);
        factory.setVault(vaultB, true);

        token.mint(vaultA, 100e6);
        token.mint(vaultB, 50e6);
        vm.prank(vaultA);
        token.transfer(address(escrow), 100e6);
        vm.prank(vaultB);
        token.transfer(address(escrow), 50e6);
    }

    function test_AccountFee_SplitsTwentyEighty() public {
        vm.prank(vaultA);
        escrow.accountFee(address(token), 20e6, 80e6, FeeEscrow.FeeType.Trading);

        assertEq(escrow.platformClaimable(address(token)), 20e6);
        assertEq(escrow.managerClaimable(managerA, address(token)), 80e6);
        assertEq(escrow.totalClaimable(address(token)), 100e6);
    }

    function test_ManagerBalanceSharedAcrossVaults() public {
        vm.prank(vaultA);
        escrow.accountFee(address(token), 20e6, 80e6, FeeEscrow.FeeType.Trading);

        vm.prank(vaultB);
        escrow.accountFee(address(token), 10e6, 40e6, FeeEscrow.FeeType.Trading);

        assertEq(escrow.managerClaimable(managerA, address(token)), 120e6);
        assertEq(escrow.platformClaimable(address(token)), 30e6);
    }

    function test_UnregisteredVaultCannotAccountFee() public {
        address fakeVault = address(new FeeEscrowVaultMock(managerA));
        token.mint(fakeVault, 10e6);
        vm.prank(fakeVault);
        token.transfer(address(escrow), 10e6);

        vm.prank(fakeVault);
        vm.expectRevert(FeeEscrow.NotRegisteredVault.selector);
        escrow.accountFee(address(token), 2e6, 8e6, FeeEscrow.FeeType.Trading);
    }

    function test_CannotAccountFeeWithoutBackingTokens() public {
        vm.prank(vaultA);
        vm.expectRevert(FeeEscrow.InsufficientEscrowBalance.selector);
        escrow.accountFee(address(token), 40e6, 160e6, FeeEscrow.FeeType.Trading);
    }

    function test_ManagerCanClaimOnlyOwnBalance() public {
        vm.prank(vaultA);
        escrow.accountFee(address(token), 20e6, 80e6, FeeEscrow.FeeType.Trading);

        vm.prank(outsider);
        vm.expectRevert(FeeEscrow.NoClaimableFees.selector);
        escrow.claimManagerFees(address(token), recipient);

        vm.prank(managerA);
        escrow.claimManagerFees(address(token), recipient);

        assertEq(token.balanceOf(recipient), 80e6);
        assertEq(escrow.managerClaimable(managerA, address(token)), 0);
    }

    function test_PlatformClaimRestrictedToTreasury() public {
        vm.prank(vaultA);
        escrow.accountFee(address(token), 20e6, 80e6, FeeEscrow.FeeType.Trading);

        vm.prank(outsider);
        vm.expectRevert(FeeEscrow.Unauthorized.selector);
        escrow.claimPlatformFees(address(token));

        vm.prank(treasury);
        escrow.claimPlatformFees(address(token));

        assertEq(token.balanceOf(treasury), 20e6);
        assertEq(escrow.platformClaimable(address(token)), 0);
    }

    function test_ClaimCannotExceedAccruedBalance() public {
        vm.prank(vaultA);
        escrow.accountFee(address(token), 20e6, 80e6, FeeEscrow.FeeType.Trading);

        vm.prank(managerA);
        escrow.claimManagerFees(address(token), recipient);

        vm.prank(managerA);
        vm.expectRevert(FeeEscrow.NoClaimableFees.selector);
        escrow.claimManagerFees(address(token), recipient);
    }

    function test_ZeroRecipientRejected() public {
        vm.prank(managerA);
        vm.expectRevert(FeeEscrow.ZeroAddress.selector);
        escrow.claimManagerFees(address(token), address(0));
    }
}
