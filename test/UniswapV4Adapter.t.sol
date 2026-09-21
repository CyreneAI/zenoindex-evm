// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract UniswapV4AdapterTest is Test {
    PoolManager internal manager;
    PoolModifyLiquidityTest internal liquidityRouter;
    UniswapV4Adapter internal adapter;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    address internal currency0Addr;
    address internal currency1Addr;

    address internal admin = address(0xADA1);
    address internal lp = address(0x11);
    address internal vaultStandIn = address(0xCACE);
    address internal recipient = address(0xBEEF);

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        manager = new PoolManager(address(this));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        adapter = new UniswapV4Adapter(address(manager), admin);

        MockERC20 t0 = new MockERC20("Token0", "TK0", 18);
        MockERC20 t1 = new MockERC20("Token1", "TK1", 18);
        if (address(t0) < address(t1)) {
            tokenA = t0;
            tokenB = t1;
        } else {
            tokenA = t1;
            tokenB = t0;
        }
        currency0Addr = address(tokenA);
        currency1Addr = address(tokenB);
        tokenC = new MockERC20("Token2", "TK2", 18);

        _initPoolAndSeed(currency0Addr, currency1Addr);
        _initPoolAndSeed(address(tokenB), address(tokenC));

        tokenA.mint(vaultStandIn, 1_000e18);
    }

    function _initPoolAndSeed(address x, address y) internal {
        (address c0, address c1) = x < y ? (x, y) : (y, x);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        MockERC20(c0).mint(lp, 1_000_000e18);
        MockERC20(c1).mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        MockERC20(c0).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(c1).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 100e18, salt: 0}),
            ""
        );
        vm.stopPrank();

        vm.prank(admin);
        adapter.setPool(c0, c1, FEE, TICK_SPACING, address(0));
    }

    function test_swap_singleHop_exactInput_swapsAndPaysRecipient() public {
        address[] memory path = new address[](2);
        path[0] = currency0Addr;
        path[1] = currency1Addr;

        vm.startPrank(vaultStandIn);
        tokenA.approve(address(adapter), 10e18);
        uint256 amountOut = adapter.swap(path, 10e18, 1, vaultStandIn, recipient);
        vm.stopPrank();

        assertGt(amountOut, 0, "amountOut should be positive");
        assertEq(tokenB.balanceOf(recipient), amountOut, "recipient should receive amountOut of tokenB");
        assertEq(tokenA.balanceOf(vaultStandIn), 990e18, "vault stand-in should have paid 10e18 tokenA");
    }

    function test_swap_twoHop_exactInput_chainsThroughIntermediate() public {
        address[] memory path = new address[](3);
        path[0] = currency0Addr; // tokenA
        path[1] = currency1Addr; // tokenB
        path[2] = address(tokenC);

        vm.startPrank(vaultStandIn);
        tokenA.approve(address(adapter), 10e18);
        uint256 amountOut = adapter.swap(path, 10e18, 1, vaultStandIn, recipient);
        vm.stopPrank();

        assertGt(amountOut, 0, "amountOut should be positive");
        assertEq(tokenC.balanceOf(recipient), amountOut, "recipient should receive amountOut of tokenC");
        assertEq(tokenB.balanceOf(address(adapter)), 0, "adapter should not retain intermediate tokenB");
    }

    function test_swap_revertsOnSlippage() public {
        address[] memory path = new address[](2);
        path[0] = currency0Addr;
        path[1] = currency1Addr;

        vm.startPrank(vaultStandIn);
        tokenA.approve(address(adapter), 10e18);
        vm.expectRevert();
        adapter.swap(path, 10e18, type(uint256).max, vaultStandIn, recipient);
        vm.stopPrank();
    }

    function test_swap_revertsWhenPoolNotSet() public {
        MockERC20 unknownToken = new MockERC20("Unknown", "UNK", 18);
        address[] memory path = new address[](2);
        path[0] = currency0Addr;
        path[1] = address(unknownToken);

        vm.startPrank(vaultStandIn);
        tokenA.approve(address(adapter), 10e18);
        vm.expectRevert(UniswapV4Adapter.PoolNotSet.selector);
        adapter.swap(path, 10e18, 0, vaultStandIn, recipient);
        vm.stopPrank();
    }

    function test_swap_revertsOnPathTooShort() public {
        address[] memory path = new address[](1);
        path[0] = currency0Addr;

        vm.startPrank(vaultStandIn);
        vm.expectRevert(UniswapV4Adapter.InvalidPath.selector);
        adapter.swap(path, 10e18, 0, vaultStandIn, recipient);
        vm.stopPrank();
    }

    function test_setPool_onlyAdmin() public {
        vm.expectRevert(UniswapV4Adapter.OnlyAdmin.selector);
        adapter.setPool(currency0Addr, currency1Addr, FEE, TICK_SPACING, address(0));
    }
}
