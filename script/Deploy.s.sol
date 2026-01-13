// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { TreasuryVault } from "../src/vault/TreasuryVault.sol";
import { TreasuryController } from "../src/controller/TreasuryController.sol";
import { MockBittensorVotes } from "../src/mocks/MockBittensorVotes.sol";

contract DeployGovernance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("Starting deployment...");
        console.log("Deployer address:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Mock
        MockBittensorVotes mock = new MockBittensorVotes();
        address votesAddress = address(mock);

        // 2. Vault
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // Any address can execute

        TreasuryVault vault = new TreasuryVault(
            30, // minDelay
            proposers,
            executors,
            deployerAddress
        );

        // 3. Governor
        TreasuryController governor = new TreasuryController(
            vault,
            votesAddress,
            1
        );

        // 4. Permissions
        bytes32 proposerRole = vault.PROPOSER_ROLE();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        vault.grantRole(proposerRole, address(governor));
        vault.renounceRole(adminRole, deployerAddress);

        vm.stopBroadcast();
        console.log("--------------------------------------------------");
        console.log("MockVotes deployed at:", address(mock));
        console.log("Vault deployed at:    ", address(vault));
        console.log("Governor deployed at: ", address(governor));
        console.log("--------------------------------------------------");
    }
}