// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Swap_mod} from "../src/Swap_mod.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../src/mocks/MockSwapRouter.sol";

contract SwapModTest is Test {
    Swap_mod internal swapMod;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockSwapRouter internal router;
    address internal zenoIndexVaultStandIn = address(this);
    address internal caller = address(0xCA11);
    address internal recipient = address(0xBEEF);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        router = new MockSwapRouter();
        swapMod = new Swap_mod(zenoIndexVaultStandIn);

        router.setRate(address(usdc), address(weth), 1e6, 1e18);
        weth.mint(address(router), 1_000e18);

        usdc.mint(caller, 1_000e6);
    }

    function test_SetRouter_OnlyZenoIndexVault() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(Swap_mod.OnlyZenoIndexVault.selector);
        swapMod.setRouter(address(router));
    }

    function test_ExecuteSwap_RoutesThroughRegisteredRouter() public {
        swapMod.setRouter(address(router));

        vm.startPrank(caller);
        usdc.approve(address(router), 100e6);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256 out = swapMod.executeSwap(path, 100e6, 1, caller, recipient);
        assertEq(out, 100e18);
        assertEq(weth.balanceOf(recipient), 100e18);
    }

    function test_ExecuteSwap_RevertsWhenNoRouterSet() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        vm.expectRevert(bytes("NO_ROUTER"));
        swapMod.executeSwap(path, 1e6, 0, caller, recipient);
    }
}
