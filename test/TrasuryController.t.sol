// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { TreasuryController, IAlphaToken } from "../src/controller/TreasuryController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    MockBittensorVotes,
    MockTarget,
    MockUidLookup,
    MockMetagraph,
    MockERC20,
    MockAlphaToken,
    RevertingReceiver
} from "./Mocks.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TreasuryControllerTest is Test {
    TreasuryController public controller;
    TimelockController public timelock;
    MockBittensorVotes public mockVotes;
    MockTarget public target;
    MockUidLookup public mockUidLookup;
    MockMetagraph public mockMetagraph;
    MockERC20 public mockToken;
    MockAlphaToken public mockAlpha;

    address public admin = makeAddr("admin");
    address public voter1 = makeAddr("voter1");
    address public voter2 = makeAddr("voter2");
    address public voter3 = makeAddr("voter3");

    uint16 constant TARGET_NETUID = 1;
    uint256 constant SUPPORT_THRESHOLD_NUMERATOR = 400;
    uint256 constant PROPOSAL_EXPIRATION_BLOCKS = 1000;
    uint256 constant TAO_LIMIT = 1000 ether;
    uint256 constant ALPHA_LIMIT = 5000 ether;
    uint256 constant ERC20_LIMIT = 10000 ether;
    uint256 constant RESET_PERIOD_MINUTES = 1440;

    address constant BITTENSOR_VOTES_ADDRESS = 0x000000000000000000000000000000000000080D;
    address constant METAGRAPH_ADDRESS = 0x0000000000000000000000000000000000000802;
    address constant UID_LOOKUP_ADDRESS = 0x0000000000000000000000000000000000000806;

    function setUp() public {
        MockBittensorVotes votesImpl = new MockBittensorVotes();
        MockUidLookup uidImpl = new MockUidLookup();
        MockMetagraph metagraphImpl = new MockMetagraph();

        vm.etch(BITTENSOR_VOTES_ADDRESS, address(votesImpl).code);
        vm.etch(UID_LOOKUP_ADDRESS, address(uidImpl).code);
        vm.etch(METAGRAPH_ADDRESS, address(metagraphImpl).code);

        mockVotes = MockBittensorVotes(BITTENSOR_VOTES_ADDRESS);
        mockUidLookup = MockUidLookup(UID_LOOKUP_ADDRESS);
        mockMetagraph = MockMetagraph(METAGRAPH_ADDRESS);

        target = new MockTarget();
        mockToken = new MockERC20();
        mockAlpha = new MockAlphaToken();

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        timelock = new TimelockController(1 days, proposers, executors, admin);

        controller = new TreasuryController(
            timelock,
            TARGET_NETUID,
            "TreasuryDAO",
            7200,
            50400,
            0,
            SUPPORT_THRESHOLD_NUMERATOR,
            PROPOSAL_EXPIRATION_BLOCKS,
            TAO_LIMIT,
            ALPHA_LIMIT,
            ERC20_LIMIT,
            RESET_PERIOD_MINUTES
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
        mockUidLookup.setLookup(TARGET_NETUID, voter, uid);
        mockMetagraph.setValidatorStatus(TARGET_NETUID, uid, isValidator);
        mockMetagraph.setHotkey(TARGET_NETUID, uid, key);
    }

    function _rollToActive() internal {
        vm.roll(block.number + controller.votingDelay() + 1);
    }

    function _rollToEnd() internal {
        vm.roll(block.number + controller.votingPeriod() + 1);
    }

    function _createNativeProposal(address proposer, uint256 amount, string memory desc) internal returns (uint256) {
        vm.prank(proposer);
        return controller.proposeNativeTransfer(address(target), amount, desc);
    }

    function _passProposal(uint256 pid) internal {
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();
    }

    function _queueAndExecuteNative(address recipient, uint256 amount, string memory desc) internal {
        bytes32 descHash = keccak256(bytes(desc));
        controller.queueNativeTransfer(recipient, amount, desc);
        vm.warp(block.timestamp + 1 days + 1);
        controller.executeNativeTransfer(recipient, amount, desc);
    }

    function test_InitialState() public view {
        assertEq(controller.name(), "TreasuryDAO");
        assertEq(controller.votingDelay(), 7200);
        assertEq(controller.votingPeriod(), 50400);
        assertEq(controller.SUPPORT_THRESHOLD_NUMERATOR(), SUPPORT_THRESHOLD_NUMERATOR);
        assertEq(controller.proposalExpirationBlocks(), PROPOSAL_EXPIRATION_BLOCKS);
        assertEq(controller.TAO_LIMIT(), TAO_LIMIT);
        assertEq(controller.ERC20_LIMIT(), ERC20_LIMIT);
        assertEq(controller.ALPHA_LIMIT(), ALPHA_LIMIT);
    }

    function test_Propose_Native() public {
        uint256 pid = _createNativeProposal(voter1, 42, "Proposal #1");
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_Propose_ERC20() public {
        vm.prank(voter1);
        uint256 pid = controller.proposeERC20Transfer(address(mockToken), address(target), 500 ether, "ERC20 Prop");
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_Propose_Alpha() public {
        vm.prank(voter1);
        uint256 pid = controller.proposeAlphaTransfer(
            address(mockAlpha), 1, bytes32("hotkey"), address(target), 100 ether, "Alpha Prop"
        );
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_Revert_GenericPropose() public {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        vm.prank(voter1);
        vm.expectRevert("Use specific propose functions");
        controller.propose(t, v, c, "Generic");
    }

    function test_Revert_GenericQueue() public {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        vm.expectRevert("Use specific queue functions");
        controller.queue(t, v, c, bytes32(0));
    }

    function test_CastVote_Succeeds_Validator() public {
        uint256 pid = _createNativeProposal(voter1, 42, "Prop");
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
        uint256 pid = _createNativeProposal(voter1, 42, "Prop");
        _rollToActive();
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.castVote(pid, 1);
    }

    function test_CastVote_Revert_NoUid() public {
        address noUidVoter = makeAddr("noUid");
        bytes32 key = bytes32(uint256(uint160(noUidVoter)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 5000);
        uint256 pid = _createNativeProposal(voter1, 42, "Prop");
        _rollToActive();
        vm.prank(noUidVoter);
        vm.expectRevert("Not a validator");
        controller.castVote(pid, 1);
    }

    function test_VoteCounting_DynamicWeights() public {
        _setupVoter(voter1, 1000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 100, "Prop");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        _setupVoter(voter1, 0, 1, true);

        uint256 pid2 = _createNativeProposal(voter1, 100, "Prop 2");
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
        uint256 amount = 999;
        string memory desc = "Execute It";
        vm.deal(address(timelock), amount);

        uint256 pid = _createNativeProposal(voter1, amount, desc);
        _passProposal(pid);

        _queueAndExecuteNative(address(target), amount, desc);
        assertEq(address(target).balance, amount);
    }

    function test_Execute_ERC20_Success() public {
        uint256 amount = 200 ether;
        string memory desc = "ERC20 Execute";
        mockToken.mint(address(timelock), amount);

        vm.prank(voter1);
        uint256 pid = controller.proposeERC20Transfer(address(mockToken), address(target), amount, desc);
        _passProposal(pid);

        controller.queueERC20Transfer(address(mockToken), address(target), amount, desc);
        vm.warp(block.timestamp + 1 days + 1);
        controller.executeERC20Transfer(address(mockToken), address(target), amount, desc);

        assertEq(mockToken.balanceOf(address(target)), amount);
    }

    function test_Execute_Alpha_Success() public {
        uint256 amount = 300 ether;
        string memory desc = "Alpha Execute";
        vm.prank(voter1);
        uint256 pid =
            controller.proposeAlphaTransfer(address(mockAlpha), 5, bytes32("hk"), address(target), amount, desc);
        _passProposal(pid);

        controller.queueAlphaTransfer(address(mockAlpha), 5, bytes32("hk"), address(target), amount, desc);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectEmit(true, true, true, true);
        emit MockAlphaToken.AlphaTransferred(5, bytes32("hk"), address(target), amount);
        controller.executeAlphaTransfer(address(mockAlpha), 5, bytes32("hk"), address(target), amount, desc);
    }

    function test_Revert_GenericExecute() public {
        address[] memory t = new address[](0);
        uint256[] memory v = new uint256[](0);
        bytes[] memory c = new bytes[](0);
        vm.expectRevert("Use specific execute functions");
        controller.execute(t, v, c, bytes32(0));
    }

    function test_State_Expired() public {
        uint256 pid = _createNativeProposal(voter1, 100, "Expires");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
        vm.roll(block.number + PROPOSAL_EXPIRATION_BLOCKS + 1);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Expired));
    }

    function test_State_Expired_ExactBoundary() public {
        uint256 pid = _createNativeProposal(voter1, 100, "Expires Boundary");
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
        string memory desc = "Expires";
        bytes32 descHash = keccak256(bytes(desc));

        uint256 pid = _createNativeProposal(voter1, 100, desc);
        _passProposal(pid);

        vm.roll(block.number + PROPOSAL_EXPIRATION_BLOCKS + 1);

        vm.expectRevert();
        controller.queueNativeTransfer(address(target), 100, desc);
    }

    function test_SetProposalExpiration_Revert_ViaGeneric() public {
        address[] memory t = new address[](1);
        t[0] = address(controller);
        uint256[] memory v = new uint256[](1);
        v[0] = 0;
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSignature("setProposalExpirationBlocks(uint256)", 5000);
        string memory desc = "Update Expiration";

        vm.prank(voter1);
        vm.expectRevert("Use specific propose functions");
        controller.propose(t, v, c, desc);
    }

    function test_ProposeAndVote_DifferentDescription_CreatesNewProposal() public {
        string memory desc = "Base Description";
        vm.prank(voter1);
        uint256 pid1 = controller.proposeNativeTransfer(address(target), 333, desc);

        string memory desc2 = "Different Description";
        vm.prank(voter1);
        uint256 pid2 = controller.proposeNativeTransfer(address(target), 333, desc2);

        assertFalse(pid1 == pid2);
        assertEq(uint256(controller.state(pid2)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_ValidatorLostStatus_BeforeVote_Revert() public {
        _setupVoter(voter1, 1000, 1, true);
        uint256 pid = _createNativeProposal(voter1, 10, "Lost Status");
        _rollToActive();

        mockMetagraph.setValidatorStatus(TARGET_NETUID, 1, false);

        vm.prank(voter1);
        vm.expectRevert("Not a validator");
        controller.castVote(pid, 1);
    }

    function test_VotingPowerReduced_DuringVote_ReturnsUpdatedWeight() public {
        _setupVoter(voter1, 1000, 1, true);
        uint256 pid = _createNativeProposal(voter1, 10, "Reduced Power");
        _rollToActive();

        bytes32 key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 100);

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Cancel_Proposal_ByProposer() public {
        uint256 pid = _createNativeProposal(voter1, 10, "To Cancel");
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));

        address[] memory t = new address[](1);
        t[0] = address(target);
        uint256[] memory v = new uint256[](1);
        v[0] = 10;
        bytes[] memory c = new bytes[](1);
        c[0] = "";

        vm.prank(voter1);
        controller.cancel(t, v, c, keccak256(bytes("To Cancel")));
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_Proposal_Fails_AgainstVotes_Majority() public {
        _setupVoter(voter1, 399, 1, true);
        _setupVoter(voter2, 600, 2, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Controversial");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);
        vm.prank(voter2);
        controller.castVote(pid, 0);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Proposal_Fails_QuorumNotReached_DespiteMajority() public {
        _setupVoter(voter1, 300, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Low Turnout");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Execute_Revert_TimelockNotReady() public {
        uint256 amount = 999;
        string memory desc = "Timelock Test";
        bytes32 descHash = keccak256(bytes(desc));

        uint256 pid = _createNativeProposal(voter1, amount, desc);
        _passProposal(pid);

        controller.queueNativeTransfer(address(target), amount, desc);

        vm.expectRevert();
        controller.executeNativeTransfer(address(target), amount, desc);
    }

    function test_Execute_Revert_BadDescriptionHash() public {
        uint256 amount = 999;
        string memory desc = "Real Description";
        string memory fakeDesc = "Fake Description";

        uint256 pid = _createNativeProposal(voter1, amount, desc);
        _passProposal(pid);

        controller.queueNativeTransfer(address(target), amount, desc);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert();
        controller.executeNativeTransfer(address(target), amount, fakeDesc);
    }

    function test_RateLimit_Enforcement() public {
        uint256 amount1 = TAO_LIMIT - 100 ether;
        uint256 amount2 = 101 ether;
        string memory desc1 = "Limit 1";
        string memory desc2 = "Limit 2";
        vm.deal(address(timelock), 2000 ether);

        uint256 pid1 = _createNativeProposal(voter1, amount1, desc1);
        uint256 pid2 = _createNativeProposal(voter1, amount2, desc2);

        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid1, 1);
        vm.prank(voter1);
        controller.castVote(pid2, 1);
        _rollToEnd();

        controller.queueNativeTransfer(address(target), amount1, desc1);
        controller.queueNativeTransfer(address(target), amount2, desc2);

        vm.warp(block.timestamp + 1 days + 1);

        controller.executeNativeTransfer(address(target), amount1, desc1);

        vm.expectRevert("Limit exceeded");
        controller.executeNativeTransfer(address(target), amount2, desc2);
    }

    function test_RateLimit_Reset() public {
        uint256 amount = TAO_LIMIT;
        string memory desc = "Full Limit";
        vm.deal(address(timelock), TAO_LIMIT * 2);

        uint256 pid = _createNativeProposal(voter1, amount, desc);
        _passProposal(pid);
        _queueAndExecuteNative(address(target), amount, desc);

        string memory desc2 = "Next Period";
        uint256 pid2 = _createNativeProposal(voter1, 100 ether, desc2);
        _passProposal(pid2);

        controller.queueNativeTransfer(address(target), 100 ether, desc2);
        vm.warp(block.timestamp + 1 days + 1);

        controller.executeNativeTransfer(address(target), 100 ether, desc2);
        assertEq(address(target).balance, amount + 100 ether);
    }

    function test_Execute_Revert_LimitRollback() public {
        uint256 amount = 100 ether;
        string memory desc = "Fail Execute";
        vm.deal(address(timelock), amount);

        RevertingReceiver failTarget = new RevertingReceiver();

        vm.prank(voter1);
        uint256 pid = controller.proposeNativeTransfer(address(failTarget), amount, desc);
        _passProposal(pid);

        controller.queueNativeTransfer(address(failTarget), amount, desc);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert("I refuse refunds");
        controller.executeNativeTransfer(address(failTarget), amount, desc);

        uint256 currentPeriod = block.timestamp / (RESET_PERIOD_MINUTES * 60);
        assertEq(controller.periodSpent(currentPeriod, bytes32(0)), 0);
    }

    function test_ProposeAndVote_Native_Lifecycle() public {
        uint256 amount = 100 ether;
        string memory desc = "P&V Native";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVoteNativeTransfer(address(target), amount, desc);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));

        _rollToActive();

        vm.prank(voter1);
        controller.proposeAndVoteNativeTransfer(address(target), amount, desc);

        assertTrue(controller.hasVoted(pid, voter1));
    }

    function test_ProposeAndVote_ERC20_Lifecycle() public {
        uint256 amount = 100 ether;
        string memory desc = "P&V ERC20";

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVoteERC20Transfer(address(mockToken), address(target), amount, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.proposeAndVoteERC20Transfer(address(mockToken), address(target), amount, desc);

        assertTrue(controller.hasVoted(pid, voter1));
    }

    function test_ProposeAndVote_Alpha_Lifecycle() public {
        uint256 amount = 100 ether;
        string memory desc = "P&V Alpha";

        vm.prank(voter1);
        uint256 pid =
            controller.proposeAndVoteAlphaTransfer(address(mockAlpha), 1, bytes32("hk"), address(target), amount, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.proposeAndVoteAlphaTransfer(address(mockAlpha), 1, bytes32("hk"), address(target), amount, desc);

        assertTrue(controller.hasVoted(pid, voter1));
    }

    function test_NewMechanism_Succeeds_ExactlyOnThreshold() public {
        _setupVoter(voter1, 400, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Exact Threshold");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_NewMechanism_Succeeds_DespiteAgainstMajority() public {
        _setupVoter(voter1, 400, 1, true);
        _setupVoter(voter2, 9600, 2, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Threshold Reached With Heavy Against");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);
        vm.prank(voter2);
        controller.castVote(pid, 0);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_NewMechanism_Defeated_BelowThreshold() public {
        _setupVoter(voter1, 399, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Below Threshold");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_NewMechanism_AgainstVotes_DoNotContributeToThreshold() public {
        _setupVoter(voter1, 10000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Only Against");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 0);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_MultiUid_AggregateVotingPower() public {
        address multiVoter = makeAddr("multiVoter");

        mockUidLookup.setLookup(TARGET_NETUID, multiVoter, 10);
        mockMetagraph.setHotkey(TARGET_NETUID, 10, bytes32(uint256(10)));
        mockMetagraph.setValidatorStatus(TARGET_NETUID, 10, true);
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(10)), 200);

        mockUidLookup.addLookup(TARGET_NETUID, multiVoter, 11);
        mockMetagraph.setHotkey(TARGET_NETUID, 11, bytes32(uint256(11)));
        mockMetagraph.setValidatorStatus(TARGET_NETUID, 11, true);
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(11)), 200);

        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(multiVoter, 10, "Aggregated Power");
        _rollToActive();

        vm.prank(multiVoter);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, multiVoter));
        assertEq(controller.getVotingPowerForAddress(multiVoter), 400);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_MultiUid_MixedValidatorStatus_Success() public {
        address mixedVoter = makeAddr("mixedVoter");

        mockUidLookup.setLookup(TARGET_NETUID, mixedVoter, 20);
        mockMetagraph.setHotkey(TARGET_NETUID, 20, bytes32(uint256(20)));
        mockMetagraph.setValidatorStatus(TARGET_NETUID, 20, false);
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(20)), 100);

        mockUidLookup.addLookup(TARGET_NETUID, mixedVoter, 21);
        mockMetagraph.setHotkey(TARGET_NETUID, 21, bytes32(uint256(21)));
        mockMetagraph.setValidatorStatus(TARGET_NETUID, 21, true);
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(21)), 300);

        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(mixedVoter, 10, "Mixed Validator Status");
        _rollToActive();

        vm.prank(mixedVoter);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, mixedVoter));
        assertEq(controller.getVotingPowerForAddress(mixedVoter), 400);

        _rollToEnd();
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_MultiUid_BothNonValidator_Revert() public {
        address nonValidator = makeAddr("nonValidatorMulti");

        mockUidLookup.setLookup(TARGET_NETUID, nonValidator, 30);
        mockMetagraph.setHotkey(TARGET_NETUID, 30, bytes32(uint256(30)));
        mockMetagraph.setValidatorStatus(TARGET_NETUID, 30, false);
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(30)), 200);

        mockUidLookup.addLookup(TARGET_NETUID, nonValidator, 31);
        mockMetagraph.setHotkey(TARGET_NETUID, 31, bytes32(uint256(31)));
        mockMetagraph.setValidatorStatus(TARGET_NETUID, 31, false);
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(31)), 200);

        uint256 pid = _createNativeProposal(voter1, 10, "Non Validator Multi");
        _rollToActive();

        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.castVote(pid, 1);
    }
}
