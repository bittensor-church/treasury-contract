// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { TreasuryController, IStakingV2 } from "../src/controller/TreasuryController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    MockBittensorVotes,
    MockTarget,
    MockUidLookup,
    MockMetagraph,
    MockERC20,
    MockStakingV2,
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
    MockStakingV2 public mockStaking;

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
    address constant STAKING_V2_ADDRESS = 0x0000000000000000000000000000000000000805;

    function setUp() public {
        MockBittensorVotes votesImpl = new MockBittensorVotes();
        MockUidLookup uidImpl = new MockUidLookup();
        MockMetagraph metagraphImpl = new MockMetagraph();
        MockStakingV2 stakingImpl = new MockStakingV2();

        vm.etch(BITTENSOR_VOTES_ADDRESS, address(votesImpl).code);
        vm.etch(UID_LOOKUP_ADDRESS, address(uidImpl).code);
        vm.etch(METAGRAPH_ADDRESS, address(metagraphImpl).code);
        vm.etch(STAKING_V2_ADDRESS, address(stakingImpl).code);

        mockVotes = MockBittensorVotes(BITTENSOR_VOTES_ADDRESS);
        mockUidLookup = MockUidLookup(UID_LOOKUP_ADDRESS);
        mockMetagraph = MockMetagraph(METAGRAPH_ADDRESS);
        mockStaking = MockStakingV2(STAKING_V2_ADDRESS);

        target = new MockTarget();
        mockToken = new MockERC20();

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
        controller.finalize(pid);
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
        uint256 pid =
            controller.proposeAlphaTransfer(bytes32("dstColdkey"), bytes32("hotkey"), 1, 1, 100 ether, "Alpha Prop");
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_ProposeNative_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.proposeNativeTransfer(address(target), 42, "Prop");
    }

    function test_ProposeNative_Revert_NoUid() public {
        address noUid = makeAddr("noUid");
        vm.prank(noUid);
        vm.expectRevert("Not a validator");
        controller.proposeNativeTransfer(address(target), 42, "Prop");
    }

    function test_ProposeERC20_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.proposeERC20Transfer(address(mockToken), address(target), 500 ether, "Prop");
    }

    function test_ProposeAlpha_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.proposeAlphaTransfer(bytes32("dstColdkey"), bytes32("hotkey"), 1, 1, 100 ether, "Prop");
    }

    function test_ProposeAndVoteNative_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.proposeAndVoteNativeTransfer(address(target), 42, "Prop");
    }

    function test_ProposeAndVoteERC20_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.proposeAndVoteERC20Transfer(address(mockToken), address(target), 500 ether, "Prop");
    }

    function test_ProposeAndVoteAlpha_Revert_NonValidator() public {
        address nonValidator = makeAddr("nonValidator");
        _setupVoter(nonValidator, 5000, 2, false);
        vm.prank(nonValidator);
        vm.expectRevert("Not a validator");
        controller.proposeAndVoteAlphaTransfer(bytes32("dstColdkey"), bytes32("hotkey"), 1, 1, 100 ether, "Prop");
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
        controller.finalize(pid);
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
        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        _setupVoter(voter1, 0, 1, true);

        uint256 pid2 = _createNativeProposal(voter1, 100, "Prop 2");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid2, 1);
        _rollToEnd();
        controller.finalize(pid2);
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
        bytes32 dst = bytes32("dstColdkey");
        bytes32 hk = bytes32("hk");
        vm.prank(voter1);
        uint256 pid = controller.proposeAlphaTransfer(dst, hk, 5, 5, amount, desc);
        _passProposal(pid);

        controller.queueAlphaTransfer(dst, hk, 5, 5, amount, desc);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectEmit(true, true, true, true);
        emit MockStakingV2.StakeTransferred(dst, hk, 5, 5, amount);
        controller.executeAlphaTransfer(dst, hk, 5, 5, amount, desc);
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
        controller.finalize(pid);
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
        controller.finalize(pid);

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
        controller.finalize(pid);
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

    function test_CastVote_Revert_AgainstSupport() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Against");
        _rollToActive();

        vm.prank(voter1);
        vm.expectRevert(TreasuryController.InvalidVoteSupport.selector);
        controller.castVote(pid, 0);
    }

    function test_CastVote_Revert_AbstainSupport() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Abstain");
        _rollToActive();

        vm.prank(voter1);
        vm.expectRevert(TreasuryController.InvalidVoteSupport.selector);
        controller.castVote(pid, 2);
    }

    function test_CastVoteBySig_Disabled() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Sig disabled");
        _rollToActive();

        vm.expectRevert(TreasuryController.VoteBySigDisabled.selector);
        controller.castVoteBySig(pid, 1, voter1, "");
    }

    function test_CastVoteWithReasonAndParamsBySig_Disabled() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Sig params disabled");
        _rollToActive();

        vm.expectRevert(TreasuryController.VoteBySigDisabled.selector);
        controller.castVoteWithReasonAndParamsBySig(pid, 1, voter1, "", "", "");
    }

    function test_Proposal_Fails_QuorumNotReached_DespiteMajority() public {
        _setupVoter(voter1, 300, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Low Turnout");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();
        controller.finalize(pid);

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
        controller.finalize(pid1);
        controller.finalize(pid2);

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
        bytes32 dst = bytes32("dstColdkey");
        bytes32 hk = bytes32("hk");

        vm.prank(voter1);
        uint256 pid = controller.proposeAndVoteAlphaTransfer(dst, hk, 1, 1, amount, desc);

        _rollToActive();

        vm.prank(voter1);
        controller.proposeAndVoteAlphaTransfer(dst, hk, 1, 1, amount, desc);

        assertTrue(controller.hasVoted(pid, voter1));
    }

    function test_NewMechanism_Succeeds_StrictlyAboveThreshold() public {
        _setupVoter(voter1, 401, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Above Threshold");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_NewMechanism_Defeated_OnExactThreshold() public {
        _setupVoter(voter1, 400, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Exact Threshold");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_NewMechanism_Defeated_BelowThreshold() public {
        _setupVoter(voter1, 399, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Below Threshold");
        _rollToActive();

        vm.prank(voter1);
        controller.castVote(pid, 1);

        _rollToEnd();
        controller.finalize(pid);
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
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(11)), 201);

        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(multiVoter, 10, "Aggregated Power");
        _rollToActive();

        vm.prank(multiVoter);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, multiVoter));
        assertEq(controller.getVotingPowerForAddress(multiVoter), 401);

        _rollToEnd();
        controller.finalize(pid);
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
        mockVotes.setVotingPower(TARGET_NETUID, bytes32(uint256(21)), 301);

        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(mixedVoter, 10, "Mixed Validator Status");
        _rollToActive();

        vm.prank(mixedVoter);
        controller.castVote(pid, 1);

        assertTrue(controller.hasVoted(pid, mixedVoter));
        assertEq(controller.getVotingPowerForAddress(mixedVoter), 401);

        _rollToEnd();
        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_Finalize_Revert_BeforeDeadline() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Too Early");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);

        vm.expectRevert(TreasuryController.NotYetFinalizable.selector);
        controller.finalize(pid);
    }

    function test_Finalize_Revert_AlreadyFinalized() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Twice");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.finalize(pid);

        vm.expectRevert(TreasuryController.AlreadyFinalized.selector);
        controller.finalize(pid);
    }

    function test_Finalize_Permissionless() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Anyone Finalizes");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        controller.finalize(pid);

        assertTrue(controller.isFinalized(pid));
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_Finalize_SnapshotsVotingPower_ImmuneToPostFinalizeDrift() public {
        _setupVoter(voter1, 1000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Snapshot Immune");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));

        bytes32 key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 0);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 1e18);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_Finalize_Defeated_NotFlippableByLaterPowerShift() public {
        _setupVoter(voter1, 300, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Below Quorum At Close");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));

        bytes32 key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 1e18);

        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_State_PostDeadlinePreFinalize_IsDefeated() public {
        uint256 pid = _createNativeProposal(voter1, 10, "Before Finalize");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        assertFalse(controller.isFinalized(pid));
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Defeated));

        controller.finalize(pid);
        assertEq(uint256(controller.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_Queue_Revert_WithoutFinalize() public {
        string memory desc = "Missing Finalize";
        uint256 pid = _createNativeProposal(voter1, 100, desc);
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        vm.expectRevert();
        controller.queueNativeTransfer(address(target), 100, desc);
    }

    function test_Finalize_EmitsEvent() public {
        _setupVoter(voter1, 1000, 1, true);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        uint256 pid = _createNativeProposal(voter1, 10, "Emit Event");
        _rollToActive();
        vm.prank(voter1);
        controller.castVote(pid, 1);
        _rollToEnd();

        uint256 expectedThreshold = (10000 * SUPPORT_THRESHOLD_NUMERATOR) / 10000;
        vm.expectEmit(true, false, false, true);
        emit TreasuryController.ProposalFinalized(pid, 1000, expectedThreshold, true);
        controller.finalize(pid);
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

    function _deployControllerWithThreshold(uint256 thresholdNumerator) internal returns (TreasuryController) {
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TimelockController tl = new TimelockController(1 days, proposers, executors, admin);
        return new TreasuryController(
            tl,
            TARGET_NETUID,
            "TreasuryDAO25",
            7200,
            50400,
            0,
            thresholdNumerator,
            PROPOSAL_EXPIRATION_BLOCKS,
            TAO_LIMIT,
            ALPHA_LIMIT,
            ERC20_LIMIT,
            RESET_PERIOD_MINUTES
        );
    }

    function test_Quorum25_Pass_At26Percent() public {
        TreasuryController c25 = _deployControllerWithThreshold(2500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        _setupVoter(voter1, 2600, 1, true);

        vm.prank(voter1);
        uint256 pid = c25.proposeNativeTransfer(address(target), 10, "26pct");

        vm.roll(block.number + c25.votingDelay() + 1);
        vm.prank(voter1);
        c25.castVote(pid, 1);

        vm.roll(block.number + c25.votingPeriod() + 1);
        c25.finalize(pid);

        assertEq(uint256(c25.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_Quorum25_Defeated_AtExactly25Percent() public {
        TreasuryController c25 = _deployControllerWithThreshold(2500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        _setupVoter(voter1, 2500, 1, true);

        vm.prank(voter1);
        uint256 pid = c25.proposeNativeTransfer(address(target), 10, "25pct exact");

        vm.roll(block.number + c25.votingDelay() + 1);
        vm.prank(voter1);
        c25.castVote(pid, 1);

        vm.roll(block.number + c25.votingPeriod() + 1);
        c25.finalize(pid);

        assertEq(uint256(c25.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Quorum25_PreFinalizeDrift_FlipsPassToDefeated() public {
        TreasuryController c25 = _deployControllerWithThreshold(2500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        _setupVoter(voter1, 2600, 1, true);

        vm.prank(voter1);
        uint256 pid = c25.proposeNativeTransfer(address(target), 10, "Pre-finalize drift");

        vm.roll(block.number + c25.votingDelay() + 1);
        vm.prank(voter1);
        c25.castVote(pid, 1);

        vm.roll(block.number + c25.votingPeriod() + 1);

        bytes32 key = bytes32(uint256(uint160(voter1)));
        mockVotes.setVotingPower(TARGET_NETUID, key, 2400);

        address griefer = makeAddr("griefer");
        vm.prank(griefer);
        c25.finalize(pid);

        assertEq(uint256(c25.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Quorum50_Defeated_25Pct_For_26Pct_Against() public {
        TreasuryController c50 = _deployControllerWithThreshold(5000);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);

        _setupVoter(voter1, 2500, 1, true);
        _setupVoter(voter2, 2600, 2, true);

        vm.prank(voter1);
        uint256 pid = c50.proposeNativeTransfer(address(target), 10, "50pct quorum");

        vm.roll(block.number + c50.votingDelay() + 1);

        vm.prank(voter1);
        c50.castVote(pid, 1);

        vm.prank(voter2);
        vm.expectRevert(TreasuryController.InvalidVoteSupport.selector);
        c50.castVote(pid, 0);

        vm.roll(block.number + c50.votingPeriod() + 1);
        c50.finalize(pid);

        assertEq(uint256(c50.state(pid)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Quorum25_PreFinalizeDrift_FlipsDefeatedToPass() public {
        TreasuryController c25 = _deployControllerWithThreshold(2500);
        mockVotes.setTotalVotingPower(TARGET_NETUID, 10000);
        _setupVoter(voter1, 2500, 1, true);

        vm.prank(voter1);
        uint256 pid = c25.proposeNativeTransfer(address(target), 10, "Total VP drop");

        vm.roll(block.number + c25.votingDelay() + 1);
        vm.prank(voter1);
        c25.castVote(pid, 1);

        vm.roll(block.number + c25.votingPeriod() + 1);

        mockVotes.setTotalVotingPower(TARGET_NETUID, 8000);

        c25.finalize(pid);

        assertEq(uint256(c25.state(pid)), uint256(IGovernor.ProposalState.Succeeded));
    }
}
