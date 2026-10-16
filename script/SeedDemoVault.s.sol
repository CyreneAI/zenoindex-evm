// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ZenoIndexVault} from "../src/ZenoIndexVault.sol";

contract SeedDemoVault is Script {
    address constant FACTORY = 0xD00ABbC1d1555a173c5081b2204579b057B05378;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 constant SEED_AMOUNT = 1_000_000;
    uint256 constant BASELINE_SHARE_PRICE = 1_000_000_000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");

        require(block.chainid == 4663, "Wrong chain");
        require(vaultAddress.code.length > 0, "Vault has no code");

        Vault vault = Vault(vaultAddress);
        ZenoIndexVault factory = ZenoIndexVault(FACTORY);
        IERC20 usdg = IERC20(USDG);

        require(vault.vaultManager() == signer, "Signer is not vault manager");
        require(vault.zenoIndexVault() == FACTORY, "Unexpected factory");
        require(!vault.genesisDone(), "Genesis already completed");
        require(!vault.paused() && !vault.adminLocked(), "Vault locked");
        require(!factory.isEmergency(), "Protocol emergency active");
        require(usdg.balanceOf(signer) >= SEED_AMOUNT, "Insufficient USDG");

        uint256 genesisShares = (SEED_AMOUNT * 1_000_000_000) / BASELINE_SHARE_PRICE;
        require(genesisShares == 1_000_000, "Unexpected genesis shares");

        vm.startBroadcast(pk);
        require(usdg.approve(vaultAddress, SEED_AMOUNT), "Approval failed");
        vault.genesisDeposit(BASELINE_SHARE_PRICE);
        vm.stopBroadcast();

        console2.log("Seeded vault:", vaultAddress);
        console2.log("Seed amount (raw USDG):", SEED_AMOUNT);
        console2.log("Genesis shares (raw):", genesisShares);
    }
}
