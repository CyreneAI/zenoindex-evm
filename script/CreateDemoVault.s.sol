// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";

contract CreateDemoVault is Script {
    address constant FACTORY = 0xD00ABbC1d1555a173c5081b2204579b057B05378;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        ZenoIndexVault factory = ZenoIndexVault(FACTORY);

        require(block.chainid == 4663, "Wrong chain");
        require(factory.superAdmin() == signer, "Signer is not super-admin");
        require(!factory.isEmergency(), "Protocol emergency active");
        require(factory.router() != address(0), "Router not configured");
        require(factory.totalAssets() == 6, "Unexpected asset count");
        require(factory.totalVaults() == 0, "Vault already exists");

        uint64[] memory assetIds = new uint64[](6);
        assetIds[0] = 0; // USDG
        assetIds[1] = 1; // NVDA
        assetIds[2] = 2; // TSLA
        assetIds[3] = 3; // META
        assetIds[4] = 4; // MU
        assetIds[5] = 5; // SPCX

        uint16[] memory allocationBps = new uint16[](6);
        allocationBps[0] = 500;
        allocationBps[1] = 3000;
        allocationBps[2] = 2000;
        allocationBps[3] = 2000;
        allocationBps[4] = 1500;
        allocationBps[5] = 1000;

        ZenoIndexVault.CreateVaultParams memory params = ZenoIndexVault.CreateVaultParams({
            feeRecipient: signer,
            depositFeeBps: 0,
            redeemFeeBps: 50,
            assetIds: assetIds,
            allocationBps: allocationBps,
            fundType: 1,
            maxShares: 0,
            name: "Zeno Demo Index",
            symbol: "ZDI"
        });

        vm.startBroadcast(pk);
        uint64 vaultId = factory.createVault(params);
        vm.stopBroadcast();

        console2.log("Simulated vault ID:", vaultId);
    }
}
