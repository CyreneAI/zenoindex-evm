// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";
import {Vault} from "../src/Vault.sol";
import {AccessMaster} from "../src/AccessMaster.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract Deploy is Script {
    uint256 internal constant MAINNET_CHAIN_ID = 4663;
    uint256 internal constant TESTNET_CHAIN_ID = 46630;

    function run() external {
        require(block.chainid == MAINNET_CHAIN_ID || block.chainid == TESTNET_CHAIN_ID, "Unsupported chain");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", deployer);
        address stablecoin = vm.envAddress("STABLECOIN");

        require(stablecoin != address(0), "STABLECOIN=0");

        address[5] memory mints = [
            vm.envAddress("ASSET_0"),
            vm.envAddress("ASSET_1"),
            vm.envAddress("ASSET_2"),
            vm.envAddress("ASSET_3"),
            vm.envAddress("ASSET_4")
        ];

        for (uint256 i; i < mints.length; ++i) {
            require(mints[i] != address(0), "Missing equity address");
            require(mints[i] != stablecoin, "Equity equals stablecoin");

            for (uint256 j; j < i; ++j) {
                require(mints[i] != mints[j], "Duplicate equity");
            }
        }

        console2.log("Chain id:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);
        console2.log("Stablecoin:", stablecoin);
        console2.log("Deployer ETH balance:", deployer.balance);

        vm.startBroadcast(pk);

        Vault vaultImpl = new Vault();
        AccessMaster accessMaster = new AccessMaster(deployer, treasury);

        ZenoIndexVault factory = new ZenoIndexVault(stablecoin, address(vaultImpl), address(accessMaster));

        FeeEscrow feeEscrow = new FeeEscrow(address(factory), address(accessMaster));

        factory.setFeeEscrow(address(feeEscrow));

        // Asset ID 0 is always the configured deposit token.
        uint64 stablecoinId = factory.createAsset(stablecoin);
        require(stablecoinId == 0, "Unexpected stablecoin ID");

        for (uint256 i; i < mints.length; ++i) {
            uint64 assetId = factory.createAsset(mints[i]);
            require(assetId == i + 1, "Unexpected equity ID");

            console2.log("Registered equity asset ID:", assetId);
            console2.log("Equity address:", mints[i]);
        }

        vm.stopBroadcast();

        console2.log("Factory:", address(factory));
        console2.log("Vault implementation:", address(vaultImpl));
        console2.log("AccessMaster:", address(accessMaster));
        console2.log("FeeEscrow:", address(feeEscrow));
        console2.log("Configured feeEscrow:", factory.feeEscrow());
        console2.log("Configured superAdmin:", factory.superAdmin());
    }
}
