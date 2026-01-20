// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { TreasuryVault } from "../src/vault/TreasuryVault.sol";

contract DeployVaultOnly is Script {
    function run() external {
        // 1. Setup environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        // Default delay is 30 seconds if not specified in .env
        uint256 minDelay = vm.envOr("MIN_DELAY", uint256(1));

        console.log("Starting deployment...");
        console.log("Deployer address:", deployerAddress);
        console.log("Min Delay:", minDelay);

        vm.startBroadcast(deployerPrivateKey);

        // 2. Configure Roles
        // create arrays containing ONLY the deployer address
        address[] memory proposers = new address[](1);
        proposers[0] = deployerAddress;

        address[] memory executors = new address[](1);
        executors[0] = deployerAddress;

        // 3. Deploy TreasuryVault
        // The deployer is passed as:
        // - Proposer (can schedule transactions)
        // - Executor (can execute transactions)
        // - Admin (can grant/revoke roles later)
        TreasuryVault vault = new TreasuryVault(
            minDelay,
            proposers,
            executors,
            deployerAddress
        );

        vm.stopBroadcast();

        console.log("--------------------------------------------------");
        console.log("TreasuryVault deployed at:", address(vault));
        console.log("Admin/Proposer/Executor set to:", deployerAddress);
        console.log("--------------------------------------------------");
    }
}