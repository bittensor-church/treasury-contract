// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { TreasuryController } from "../src/controller/TreasuryController.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { MockBittensorVotes, MockTarget } from "./ControllerMocks.sol";

contract TreasuryControllerTest is Test {
    TreasuryController public controller;
    TimelockController public timelock;
    MockBittensorVotes public mockVotes;
    MockTarget public target;

    address public admin = makeAddr("admin");
    address public voter1 = makeAddr("voter1");
    address public voter2 = makeAddr("voter2");
    address public voter3 = makeAddr("voter3");

    uint16 constant TARGET_NETUID = 1;
    uint256 constant QUORUM_NUMERATOR = 400;

    function setUp() public {
        mockVotes = new MockBittensorVotes();
        target = new MockTarget();

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        timelock = new TimelockController(
            1 days,
            proposers,
            executors,
            admin
        );

        controller = new TreasuryController(
            timelock,
            address(mockVotes),
            TARGET_NETUID,
            "TreasuryDAO",
            7200,
            50400,
            0,
            QUORUM_NUMERATOR
        );

        vm.startPrank(admin);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(controller));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(controller));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(controller));
        vm.stopPrank();

        vm.warp(100);
        vm.roll(100);
    }

    function test_InitialState() public view {
        assertEq(controller.name(), "TreasuryDAO");
        assertEq(controller.votingDelay(), 7200);
        assertEq(controller.votingPeriod(), 50400);
        assertEq(controller.QUORUM_NUMERATOR(), QUORUM_NUMERATOR);
    }

    function test_Propose() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        string memory description = "Proposal #1: Set value to 42";

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, description);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_CastVote_Succeeds() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 42);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Prop");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, voter1));
    }

    function test_VoteCounting_DynamicWeights() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 100);

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 1000);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Prop");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.roll(block.number + controller.votingPeriod() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 0);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Quorum() public {
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        uint256 quorum = controller.quorum(block.number);
        assertEq(quorum, 400);
    }

    function test_Quorum_NotReached() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 100);

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 300);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Prop");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.roll(block.number + controller.votingPeriod() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_FullLifecycle_Execute() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 999);
        string memory description = "Execute It";
        bytes32 descriptionHash = keccak256(bytes(description));

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, description);

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.roll(block.number + controller.votingPeriod() + 1);

        controller.queue(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + 1 days + 1);

        controller.execute(targets, values, calldatas, descriptionHash);

        assertEq(target.value(), 999);
    }

    function test_VoteAgainst() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 100);

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        bytes32 v2Key = bytes32(uint256(uint160(voter2)));

        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 400);
        mockVotes.setVotingPower(TARGET_NETUID, v2Key, 600);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Vote");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter2);
        controller.castVote(pid, 0);

        vm.roll(block.number + controller.votingPeriod() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_DoubleVote_UpdatesVote() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 1);

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 1000);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Prop");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter1);
        controller.castVote(pid, 0);

        vm.roll(block.number + controller.votingPeriod() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_State_Active() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Prop");

        vm.roll(block.number + controller.votingDelay() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Active));
    }

    function test_Tie_Defeated() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        bytes32 v2Key = bytes32(uint256(uint160(voter2)));

        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 500);
        mockVotes.setVotingPower(TARGET_NETUID, v2Key, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Tie");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter2);
        controller.castVote(pid, 0);

        vm.roll(block.number + controller.votingPeriod() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_CastVote_Revert_InvalidType() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Prop");
        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        vm.expectRevert("Invalid vote type");
        controller.castVote(pid, 2);
    }

    function test_Queue_Revert_ProposalNotSucceeded() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";
        string memory desc = "Desc";
        bytes32 descHash = keccak256(bytes(desc));

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, desc);

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.expectRevert();
        controller.queue(targets, values, calldatas, descHash);
    }

    function test_Execute_Revert_TimelockNotReady() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 999);
        string memory desc = "Execute Early";
        bytes32 descHash = keccak256(bytes(desc));

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, desc);

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.roll(block.number + controller.votingPeriod() + 1);

        controller.queue(targets, values, calldatas, descHash);

        vm.expectRevert();
        controller.execute(targets, values, calldatas, descHash);
    }

    function test_Governance_SelfUpdate_Settings() public {
        address[] memory targets = new address[](1);
        targets[0] = address(controller);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVotingDelay(uint48)", uint48(10000));
        string memory desc = "Update Delay";
        bytes32 descHash = keccak256(bytes(desc));

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, desc);

        vm.roll(block.number + controller.votingDelay() + 1);
        vm.prank(voter1);
        controller.castVote(pid, 1);
        vm.roll(block.number + controller.votingPeriod() + 1);

        controller.queue(targets, values, calldatas, descHash);
        vm.warp(block.timestamp + 1 days + 1);
        controller.execute(targets, values, calldatas, descHash);

        assertEq(controller.votingDelay(), 10000);
    }

    function test_OnlyGovernance_CanUpdateSettings() public {
        vm.prank(voter1);
        vm.expectRevert();
        controller.setVotingDelay(12345);
    }

    function test_Vote_WithZeroPower_DoesNotAffectOutcome() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        bytes32 v1Key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, v1Key, 0);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(targets, values, calldatas, "Zero Power");

        vm.roll(block.number + controller.votingDelay() + 1);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.roll(block.number + controller.votingPeriod() + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }
}