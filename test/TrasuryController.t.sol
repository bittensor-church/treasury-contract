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

        _setVotingPower(voter1, 1000);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.warp(100);
        vm.roll(100);
    }

    function _createProposalArgs(uint256 valueToSet) internal view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) {
        targets = new address[](1);
        targets[0] = address(target);
        values = new uint256[](1);
        values[0] = 0;
        calldatas = new bytes[](1);
        if (valueToSet > 0) {
            calldatas[0] = abi.encodeWithSignature("setValue(uint256)", valueToSet);
        } else {
            calldatas[0] = "";
        }
    }

    function _setVotingPower(address voter, uint256 amount) internal {
        bytes32 key = bytes32(uint256(uint160(voter)));
        mockVotes.setVotingPower(TARGET_NETUID, key, amount);
    }

    function _rollToActive() internal {
        vm.roll(block.number + controller.votingDelay() + 1);
    }

    function _rollToEnd() internal {
        vm.roll(block.number + controller.votingPeriod() + 1);
    }

    function test_InitialState() public view {
        assertEq(controller.name(), "TreasuryDAO");
        assertEq(controller.votingDelay(), 7200);
        assertEq(controller.votingPeriod(), 50400);
        assertEq(controller.QUORUM_NUMERATOR(), QUORUM_NUMERATOR);
    }

    function test_Propose() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(42);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Proposal #1");

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_CastVote_Succeeds() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(42);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, voter1));
    }

    function test_VoteCounting_DynamicWeights() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);

        _setVotingPower(voter1, 1000);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        _setVotingPower(voter1, 0);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Quorum() public {
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        uint256 quorum = controller.quorum(block.number);
        assertEq(quorum, 400);
    }

    function test_Quorum_NotReached() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);

        _setVotingPower(voter1, 300);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_FullLifecycle_Execute() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(999);
        string memory desc = "Execute It";
        bytes32 descHash = keccak256(bytes(desc));

        _setVotingPower(voter1, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        controller.queue(t, v, c, descHash);

        vm.warp(block.timestamp + 1 days + 1);

        controller.execute(t, v, c, descHash);

        assertEq(target.value(), 999);
    }

    function test_VoteAgainst() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);

        _setVotingPower(voter1, 400);
        _setVotingPower(voter2, 600);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Vote");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter2);
        controller.castVote(pid, 0);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_DoubleVote_UpdatesVote() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(1);

        _setVotingPower(voter1, 1000);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter1);
        controller.castVote(pid, 0);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_State_Active() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(0);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Active));
    }

    function test_Tie_Defeated() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(0);

        _setVotingPower(voter1, 500);
        _setVotingPower(voter2, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Tie");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter2);
        controller.castVote(pid, 0);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_CastVote_Revert_InvalidType() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(0);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");
        _rollToActive();

        vm.prank(voter1);
        vm.expectRevert("Invalid vote type");
        controller.castVote(pid, 2);
    }

    function test_Queue_Revert_ProposalNotSucceeded() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(0);
        string memory desc = "Desc";
        bytes32 descHash = keccak256(bytes(desc));

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);

        _rollToActive();

        vm.expectRevert();
        controller.queue(t, v, c, descHash);
    }

    function test_Execute_Revert_TimelockNotReady() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(999);
        string memory desc = "Execute Early";
        bytes32 descHash = keccak256(bytes(desc));

        _setVotingPower(voter1, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        controller.queue(t, v, c, descHash);

        vm.expectRevert();
        controller.execute(t, v, c, descHash);
    }

    function test_Governance_SelfUpdate_Settings() public {
        address[] memory t = new address[](1);
        t[0] = address(controller);
        uint256[] memory v = new uint256[](1);
        v[0] = 0;
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSignature("setVotingDelay(uint48)", uint48(10000));

        string memory desc = "Update Delay";
        bytes32 descHash = keccak256(bytes(desc));

        _setVotingPower(voter1, 500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.queue(t, v, c, descHash);
        vm.warp(block.timestamp + 1 days + 1);
        controller.execute(t, v, c, descHash);

        assertEq(controller.votingDelay(), 10000);
    }

    function test_OnlyGovernance_CanUpdateSettings() public {
        vm.prank(voter1);
        vm.expectRevert();
        controller.setVotingDelay(12345);
    }

    function test_Vote_WithZeroPower_DoesNotAffectOutcome() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(0);

        _setVotingPower(voter1, 0);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Zero Power");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_ProposeAndVote_NewProposal_CreatesPending() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(55);
        string memory desc = "New Proposal";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVote(t, v, c, desc);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
        assertFalse(controller.hasVoted(pid, voter1));
    }

    function test_ProposeAndVote_ExistingProposal_Pending_Reverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(66);
        string memory desc = "Pending Revert";

        vm.prank(voter1);
        controller.proposeAndVote(t, v, c, desc);

        vm.prank(voter2);
        vm.expectRevert("Proposal exists but is Pending (wait for voting delay)");
        controller.proposeAndVote(t, v, c, desc);
    }

    function test_ProposeAndVote_ExistingProposal_Active_CastsVote() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(77);
        string memory desc = "Active Vote";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVote(t, v, c, desc);

        _rollToActive();

        _setVotingPower(voter2, 500);

        vm.prank(voter2);
        uint256 pid2 = controller.proposeAndVote(t, v, c, desc);

        assertEq(pid, pid2);
        assertTrue(controller.hasVoted(pid, voter2));
    }

    function test_ProposeAndVote_ExistingProposal_Active_AlreadyVoted_DoesNotRevert() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(88);
        string memory desc = "Idempotency";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVote(t, v, c, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter1);
        uint256 pidRet = controller.proposeAndVote(t, v, c, desc);

        assertEq(pid, pidRet);
    }

    function test_ProposeAndVote_ExistingProposal_Defeated_Reverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(99);
        string memory desc = "Defeated check";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVote(t, v, c, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 0);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));

        vm.prank(voter2);
        vm.expectRevert("Proposal exists but voting is closed");
        controller.proposeAndVote(t, v, c, desc);
    }

    function test_ProposeAndVote_ExistingProposal_Succeeded_Reverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(111);
        string memory desc = "Succeeded check";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVote(t, v, c, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        vm.prank(voter2);
        vm.expectRevert("Proposal exists but voting is closed");
        controller.proposeAndVote(t, v, c, desc);
    }

    function test_ProposeAndVote_ExistingProposal_Executed_Reverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(222);
        string memory desc = "Executed check";
        bytes32 descHash = keccak256(bytes(desc));

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVote(t, v, c, desc);

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.queue(t, v, c, descHash);

        vm.warp(block.timestamp + 1 days + 1);

        controller.execute(t, v, c, descHash);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Executed));

        vm.prank(voter2);
        vm.expectRevert("Proposal exists but voting is closed");
        controller.proposeAndVote(t, v, c, desc);
    }

    function test_ProposeAndVote_DifferentDescription_CreatesNewProposal() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(333);
        string memory desc = "Base Description";

        vm.prank(voter1);
        uint256 pid1 = controller.proposeAndVote(t, v, c, desc);

        string memory desc2 = "Different Description";
        vm.prank(voter1);
        uint256 pid2 = controller.proposeAndVote(t, v, c, desc2);

        assertFalse(pid1 == pid2);
        assertEq(uint256(controller.state(pid2)), uint256(IGovernor.ProposalState.Pending));
    }
}