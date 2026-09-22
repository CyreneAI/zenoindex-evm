// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {NavCalculation} from "../src/NavCalculation.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Minimal stand-in exposing just the IZenoIndexVault surface NavCalculation needs.
contract FakeZenoIndexVault {
    address public usdcToken;
    mapping(uint64 => address) internal mints;

    constructor(address usdc_) {
        usdcToken = usdc_;
    }

    function setAssetMint(uint64 assetId, address mint) external {
        mints[assetId] = mint;
    }

    function getAsset(uint64 assetId) external view returns (uint64, address, bool, bool) {
        return (assetId, mints[assetId], true, true);
    }
}

contract NavCalculationTest is Test {
    NavCalculation internal navCalculation;
    FakeZenoIndexVault internal zenoIndexVault;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    address internal vaultClone = address(0xC10E);

    function setUp() public {
        navCalculation = new NavCalculation();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        zenoIndexVault = new FakeZenoIndexVault(address(usdc));

        zenoIndexVault.setAssetMint(0, address(usdc));
        zenoIndexVault.setAssetMint(1, address(weth));
        navCalculation.setPriceWhole(address(weth), 2_000_000); // $2 per WETH
    }

    function test_SumNav_UsdcSlotExcludesPendingAndReserved() public {
        usdc.mint(vaultClone, 1_000_000); // 1.0 USDC raw
        weth.mint(vaultClone, 1e18); // 1.0 WETH raw

        uint64[] memory ids = new uint64[](2);
        ids[0] = 0;
        ids[1] = 1;
        uint256[] memory reserved = new uint256[](2);
        reserved[0] = 0;
        reserved[1] = 0;

        uint256 total =
            navCalculation.sumNav(address(zenoIndexVault), vaultClone, ids, reserved, 400_000);
        // USDC leg: 1_000_000 - 400_000 pending = 600_000
        // WETH leg: 1e18 * $2 = 2_000_000 (6dp USDC)
        assertEq(total, 600_000 + 2_000_000);
    }

    function test_SumNav_SubtractsReservedBeforeValuing() public {
        weth.mint(vaultClone, 1e18);

        uint64[] memory ids = new uint64[](1);
        ids[0] = 1;
        uint256[] memory reserved = new uint256[](1);
        reserved[0] = 0.5e18; // half reserved for pending redemption

        uint256 total = navCalculation.sumNav(address(zenoIndexVault), vaultClone, ids, reserved, 0);
        assertEq(total, 1_000_000); // 0.5 WETH free * $2
    }

    function test_SumNav_RevertsOnLengthMismatch() public {
        uint64[] memory ids = new uint64[](2);
        uint256[] memory reserved = new uint256[](1);
        vm.expectRevert(bytes("LEN"));
        navCalculation.sumNav(address(zenoIndexVault), vaultClone, ids, reserved, 0);
    }

    function test_ValueUsdc_UsdcIsOneToOne_NonUsdcUsesPriceTable() public {
        assertEq(navCalculation.valueUsdc(address(zenoIndexVault), address(usdc), 5_000_000), 5_000_000);
        assertEq(navCalculation.valueUsdc(address(zenoIndexVault), address(weth), 1e18), 2_000_000);
    }

    function test_ValueUsdc_RevertsWhenPriceUnset() public {
        MockERC20 unset = new MockERC20("Unset", "UNS", 6);
        vm.expectRevert(NavCalculation.NoPrice.selector);
        navCalculation.valueUsdc(address(zenoIndexVault), address(unset), 1e6);
    }
}
