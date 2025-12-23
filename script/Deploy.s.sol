// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TreasuryVault} from "../src/vault/TreasuryVault.sol";
import {TreasuryController} from "../src/controller/TreasuryController.sol";
import {MockBittensorVotes} from "../src/mocks/MockBittensorVotes.sol";
import {IVotes} from "lib/openzeppelin-contracts/contracts/governance/utils/IVotes.sol";

contract DeployGovernance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("Starting deployment...");
        console.log("Deployer address:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. ALWAYS deploy MockBittensorVotes
        MockBittensorVotes mock = new MockBittensorVotes();
        address votesAddress = address(mock);

        // 2. Deploy Vault
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TreasuryVault vault = new TreasuryVault(
            172800, // minDelay
            proposers,
            executors,
            deployerAddress
        );

        // 3. Deploy Governor using the Mock address
        TreasuryController governor = new TreasuryController(
            IVotes(votesAddress),
            vault,
            votesAddress,
            1
        );

// 4. Permissions Setup
        bytes32 PROPOSER_ROLE = vault.PROPOSER_ROLE();

        // ZMIANA TUTAJ: W OpenZeppelin v5 admin timelocka to po prostu DEFAULT_ADMIN_ROLE
        bytes32 ADMIN_ROLE = vault.DEFAULT_ADMIN_ROLE();

        vault.grantRole(PROPOSER_ROLE, address(governor));
        vault.renounceRole(ADMIN_ROLE, deployerAddress);

        vm.stopBroadcast();
        console.log("--------------------------------------------------");
        console.log("MockVotes deployed at:", address(mock));
        console.log("Vault deployed at:    ", address(vault));
        console.log("Governor deployed at: ", address(governor));
        console.log("--------------------------------------------------");
        console.log("NOTE: Use MockVotes.setVotingPower() to simulate stake.");
    }
}