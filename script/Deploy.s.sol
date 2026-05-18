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

        uint256 minDelay = vm.envOr("MIN_DELAY", uint256(1));
        uint256 netuid = vm.envOr("NETUID", uint256(2));
        uint256 proposalExpirationBlocks = vm.envOr("PROPOSAL_EXPIRATION", uint256(1000));

        string memory govName = vm.envOr("GOV_NAME", string("BittensorDAO"));
        uint256 votingDelayEnv = vm.envOr("VOTING_DELAY", uint256(0));
        uint256 votingPeriodEnv = vm.envOr("VOTING_PERIOD", uint256(5));
        uint256 proposalThresholdEnv = vm.envOr("PROPOSAL_THRESHOLD", uint256(0));
        uint256 quorumNumeratorEnv = vm.envOr("QUORUM_BPS", uint256(5000));

        uint256 taoLimit = vm.envOr("TAO_LIMIT", uint256(1000 ether));
        uint256 alphaLimit = vm.envOr("ALPHA_LIMIT", uint256(5000 ether));
        uint256 erc20Limit = vm.envOr("ERC20_LIMIT", uint256(10000 ether));
        uint256 resetPeriod = vm.envOr("LIMIT_RESET_PERIOD_MIN", uint256(10080)); // Default: 1 week
        uint256 proposalResetPeriod = vm.envOr("PROPOSAL_LIMIT_RESET_PERIOD_MIN", uint256(1440)); // Default: 1 day
        uint256 proposalLimitPerUid = vm.envOr("PROPOSAL_LIMIT_PER_UID", uint256(100));

        uint48 votingDelay = uint48(votingDelayEnv);
        uint32 votingPeriod = uint32(votingPeriodEnv);

        console.log("Starting deployment...");
        console.log("Deployer address:", deployerAddress);
        console.log("NetUID:", netuid);
        console.log("TAO Limit:", taoLimit);
        console.log("Alpha Limit:", alphaLimit);
        console.log("ERC20 Limit:", erc20Limit);
        console.log("Reset Period (Min):", resetPeriod);
        console.log("Proposal Reset Period (Min):", proposalResetPeriod);
        console.log("Proposal Limit Per UID:", proposalLimitPerUid);

        vm.startBroadcast(deployerPrivateKey);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        TreasuryVault vault = new TreasuryVault(minDelay, proposers, executors, deployerAddress);

        TreasuryController governor = new TreasuryController(
            vault,
            uint16(netuid),
            govName,
            votingDelay,
            votingPeriod,
            proposalThresholdEnv,
            quorumNumeratorEnv,
            proposalExpirationBlocks,
            taoLimit,
            alphaLimit,
            erc20Limit,
            resetPeriod,
            proposalResetPeriod,
            proposalLimitPerUid
        );

        bytes32 proposerRole = vault.PROPOSER_ROLE();
        bytes32 executorRole = vault.EXECUTOR_ROLE();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        vault.grantRole(proposerRole, address(governor));
        vault.grantRole(executorRole, address(governor));
        vault.renounceRole(adminRole, deployerAddress);

        vm.stopBroadcast();

        console.log("--------------------------------------------------");
        console.log("Vault deployed at:    ", address(vault));
        console.log("Governor deployed at: ", address(governor));
        console.log("--------------------------------------------------");
    }
}
