// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { TreasuryVault } from "../src/vault/TreasuryVault.sol";
import { TreasuryController } from "../src/controller/TreasuryController.sol";

contract DeployGovernance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        uint256 minDelay = vm.envOr("MIN_DELAY", uint256(1)); // 1 block delay for testing
        uint256 netuid = vm.envOr("NETUID", uint256(2));
        uint256 proposalExpirationBlocks = vm.envOr("PROPOSAL_EXPIRATION", uint256(1000));

        string memory govName = vm.envOr("GOV_NAME", string("BittensorDAO"));
        uint256 votingDelayEnv = vm.envOr("VOTING_DELAY", uint256(0));
        uint256 votingPeriodEnv = vm.envOr("VOTING_PERIOD", uint256(5)); // 5 blocks for testing
        uint256 proposalThresholdEnv = vm.envOr("PROPOSAL_THRESHOLD", uint256(0));
        uint256 quorumNumeratorEnv = vm.envOr("QUORUM_BPS", uint256(100)); // 1% quorum for testing

        uint48 votingDelay = uint48(votingDelayEnv);
        uint32 votingPeriod = uint32(votingPeriodEnv);
        uint256 proposalThreshold = proposalThresholdEnv;

        console.log("Starting deployment...");
        console.log("Deployer address:", deployerAddress);
        console.log("Min Delay (Timelock):", minDelay);
        console.log("NetUID:", netuid);
        console.log("Governor Name:", govName);
        console.log("Voting Delay:", votingDelay);
        console.log("Voting Period:", votingPeriod);
        console.log("Proposal Threshold:", proposalThreshold);
        console.log("Quorum Numerator (BPS):", quorumNumeratorEnv);

        vm.startBroadcast(deployerPrivateKey);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        TreasuryVault vault = new TreasuryVault(minDelay, proposers, executors, deployerAddress);

        TreasuryController governor = new TreasuryController(
            vault,
            uint16(netuid),
            govName,
            votingDelay,
            votingPeriod,
            proposalThreshold,
            quorumNumeratorEnv,
            proposalExpirationBlocks
        );

        bytes32 proposerRole = vault.PROPOSER_ROLE();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        vault.grantRole(proposerRole, address(governor));
        vault.renounceRole(adminRole, deployerAddress);

        vm.stopBroadcast();

        console.log("--------------------------------------------------");
        console.log("Vault deployed at:    ", address(vault));
        console.log("Governor deployed at: ", address(governor));
        console.log("--------------------------------------------------");
    }
}

