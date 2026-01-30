// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { TreasuryController } from "../src/controller/TreasuryController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { MockBittensorVotes, MockTarget, MockUidLookup, MockMetagraph } from "./Mocks.sol";

contract TreasuryControllerTest is Test {
    TreasuryController public controller;
    TimelockController public timelock;
    MockBittensorVotes public mockVotes;
    MockTarget public target;
    MockUidLookup public mockUidLookup;
    MockMetagraph public mockMetagraph;

    address public admin = makeAddr("admin");
    address public voter1 = makeAddr("voter1");
    address public voter2 = makeAddr("voter2");
    address public voter3 = makeAddr("voter3");

    uint16 constant TARGET_NETUID = 1;
    uint256 constant QUORUM_NUMERATOR = 400;
    uint256 constant PROPOSAL_EXPIRATION_BLOCKS = 1000;

    address constant METAGRAPH_ADDRESS = 0x0000000000000000000000000000000000000802;
    address constant UID_LOOKUP_ADDRESS = 0x0000000000000000000000000000000000000806;

    function setUp() public {
        mockVotes = new MockBittensorVotes();
        target = new MockTarget();
        mockUidLookup = new MockUidLookup();
        mockMetagraph = new MockMetagraph();

        vm.etch(UID_LOOKUP_ADDRESS, address(mockUidLookup).code);
        vm.etch(METAGRAPH_ADDRESS, address(mockMetagraph).code);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        timelock = new TimelockController(1 days, proposers, executors, admin);

        controller = new TreasuryController(
            timelock,
            address(mockVotes),
            TARGET_NETUID,
            "TreasuryDAO",
            7200,
            50400,
            0,
            QUORUM_NUMERATOR,
            PROPOSAL_EXPIRATION_BLOCKS
        );

        vm.startPrank(admin);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(controller));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(controller));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(controller));
        vm.stopPrank();

        _setupVoter(voter1, 1000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.warp(100);
        vm.roll(100);
    }

    function _setupVoter(address voter, uint256 amount, uint16 uid, bool isValidator) internal {
        bytes32 key = bytes32(uint256(uint160(voter)));
        mockVotes.setVotingPower(TARGET_NETUID, key, amount);

        MockUidLookup(UID_LOOKUP_ADDRESS).setLookup(TARGET_NETUID, voter, uid);
        MockMetagraph(METAGRAPH_ADDRESS).setValidatorStatus(TARGET_NETUID, uid, isValidator);
    }

    function _createProposalArgs(uint256 valueToSet)
    internal
    view
    returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
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
        assertEq(controller.proposalExpirationBlocks(), PROPOSAL_EXPIRATION_BLOCKS);
    }

    function test_Propose() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(42);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Proposal #1");

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_CastVote_Succeeds_Validator() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(42);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, voter1));

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_CastVote_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(42);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.castVote(pid, 1);
    }

    function test_CastVote_Revert_NoUid() public {
        address noUidVoter = makeAddr("noUid");
        bytes32 key = bytes32(uint256(uint160(noUidVoter)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 5000);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(42);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(noUidVoter);
        vm.expectRevert("No UID associated with address");
        controller.castVote(pid, 1);
    }

    function test_VoteCounting_DynamicWeights() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);

        _setupVoter(voter1, 1000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Prop");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        _setupVoter(voter1, 0, 1, true);

        vm.prank(voter1);
        uint256 pid2 = controller.propose(t, v, c, "Prop 2");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid2, 1);
        _rollToEnd();

        assertEq(uint256(controller.state(pid2)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Quorum() public {
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        uint256 quorum = controller.quorum(block.number);
        assertEq(quorum, 400);
    }

    function test_FullLifecycle_Execute() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(999);
        string memory desc = "Execute It";
        bytes32 descHash = keccak256(bytes(desc));

        _setupVoter(voter1, 500, 1, true);
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

    function test_State_Expired() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);

        _setupVoter(voter1, 1000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Expires");

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        vm.roll(block.number + PROPOSAL_EXPIRATION_BLOCKS + 1);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Expired));
    }

    function test_State_Expired_ExactBoundary() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);

        _setupVoter(voter1, 1000, 1, true);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Expires Boundary");

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        uint256 deadline = controller.proposalDeadline(pid);

        vm.roll(deadline + PROPOSAL_EXPIRATION_BLOCKS);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        vm.roll(deadline + PROPOSAL_EXPIRATION_BLOCKS + 1);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Expired));
    }

    function test_Queue_Revert_Expired() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(100);
        string memory desc = "Expires";
        bytes32 descHash = keccak256(bytes(desc));

        _setupVoter(voter1, 1000, 1, true);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        vm.roll(block.number + PROPOSAL_EXPIRATION_BLOCKS + 1);

        vm.expectRevert();
        controller.queue(t, v, c, descHash);
    }

    function test_SetProposalExpiration_OnlyGovernance() public {
        uint256 newExpiration = 5000;
        address[] memory t = new address[](1);
        t[0] = address(controller);
        uint256[] memory v = new uint256[](1);
        v[0] = 0;
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSignature("setProposalExpirationBlocks(uint256)", newExpiration);

        string memory desc = "Update Expiration";
        bytes32 descHash = keccak256(bytes(desc));

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.queue(t, v, c, descHash);
        vm.warp(block.timestamp + 1 days + 1);
        controller.execute(t, v, c, descHash);

        assertEq(controller.proposalExpirationBlocks(), newExpiration);
    }

    function test_SetProposalExpiration_Revert_Unauthorized() public {
        vm.prank(voter1);
        vm.expectRevert();
        controller.setProposalExpirationBlocks(9999);
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

    function test_ValidatorLostStatus_BeforeVote_Revert() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(10);

        _setupVoter(voter1, 1000, 1, true);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Lost Status");

        _rollToActive();

        MockMetagraph(METAGRAPH_ADDRESS).setValidatorStatus(TARGET_NETUID, 1, false);

        vm.prank(voter1);
        vm.expectRevert("Not a validator");
        controller.castVote(pid, 1);
    }

    function test_VotingPowerReduced_DuringVote_ReturnsUpdatedWeight() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(10);

        _setupVoter(voter1, 1000, 1, true);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Reduced Power");

        _rollToActive();

        bytes32 key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 100);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Cancel_Proposal_ByProposer() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(10);

        _setupVoter(voter1, 1000, 1, true);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "To Cancel");

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));

        vm.prank(voter1);
        controller.cancel(t, v, c, keccak256(bytes("To Cancel")));

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_Proposal_Fails_AgainstVotes_Majority() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(10);

        _setupVoter(voter1, 400, 1, true);
        _setupVoter(voter2, 600, 2, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Controversial");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.prank(voter2);
        controller.castVote(pid, 0);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Proposal_Fails_QuorumNotReached_DespiteMajority() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(10);

        _setupVoter(voter1, 300, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, "Low Turnout");

        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Execute_Revert_TimelockNotReady() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(999);
        string memory desc = "Timelock Test";
        bytes32 descHash = keccak256(bytes(desc));

        _setupVoter(voter1, 500, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

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

    function test_Execute_Revert_BadDescriptionHash() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _createProposalArgs(999);
        string memory desc = "Real Description";
        bytes32 realHash = keccak256(bytes(desc));
        bytes32 fakeHash = keccak256(bytes("Fake Description"));

        _setupVoter(voter1, 500, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        vm.prank(voter1);
        uint256 pid = controller.propose(t, v, c, desc);

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.queue(t, v, c, realHash);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert();
        controller.execute(t, v, c, fakeHash);
    }
}