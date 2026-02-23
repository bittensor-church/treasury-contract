// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct LookupItem {
    uint16 uid;
    uint64 block_associated;
}

interface IUidLookup {
    function uidLookup(uint16 netuid, address evm_address, uint16 limit) external view returns (LookupItem[] memory);
}

interface IMetagraph {
    function getValidatorStatus(uint16 netuid, uint16 uid) external view returns (bool);
    function getHotkey(uint16 netuid, uint16 uid) external view returns (bytes32);
}

interface IBittensorVotes {
    function getVotingPower(uint16 netuid, bytes32 hotkey) external view returns (uint256);
    function getTotalVotingPower(uint16 netuid) external view returns (uint256);
}

interface IAlphaToken {
    function transferAlpha(uint16 netuid, bytes32 hotkey, address recipient, uint256 amount) external;
}

contract TreasuryController is Governor, GovernorSettings, GovernorTimelockControl {
    address constant BITTENSOR_VOTES_ADDRESS = 0x000000000000000000000000000000000000080D;
    address constant METAGRAPH_ADDRESS = 0x0000000000000000000000000000000000000802;
    address constant UID_LOOKUP_ADDRESS = 0x0000000000000000000000000000000000000806;

    uint16 public immutable TARGET_NETUID;
    uint256 public immutable SUPPORT_THRESHOLD_NUMERATOR;

    uint256 public immutable TAO_LIMIT;
    uint256 public immutable ALPHA_LIMIT;
    uint256 public immutable ERC20_LIMIT;
    uint256 public immutable LIMIT_RESET_PERIOD;

    uint256 public proposalExpirationBlocks;

    struct ProposalTallies {
        bytes32[] votedHotkeys;
        mapping(bytes32 => uint8) hotkeySupport;
        bool counted;
        uint256 forVotes;
        uint256 againstVotes;
    }

    mapping(uint256 => ProposalTallies) private _proposalTallies;
    mapping(uint256 => mapping(bytes32 => uint256)) public periodSpent;

    modifier onlyValidator(address account) {
        uint16 uid = getUidForAddress(account);
        require(IMetagraph(METAGRAPH_ADDRESS).getValidatorStatus(TARGET_NETUID, uid), "Not a validator");
        _;
    }

    constructor(
        TimelockController _timelock,
        uint16 _netuid,
        string memory _name,
        uint48 _initialVotingDelay,
        uint32 _initialVotingPeriod,
        uint256 _initialProposalThreshold,
        uint256 _supportThresholdNumerator,
        uint256 _proposalExpirationBlocks,
        uint256 _taoLimit,
        uint256 _alphaLimit,
        uint256 _erc20Limit,
        uint256 _limitResetPeriodMinutes
    )
    Governor(_name)
    GovernorSettings(_initialVotingDelay, _initialVotingPeriod, _initialProposalThreshold)
    GovernorTimelockControl(_timelock)
    {
        TARGET_NETUID = _netuid;
        SUPPORT_THRESHOLD_NUMERATOR = _supportThresholdNumerator;
        proposalExpirationBlocks = _proposalExpirationBlocks;

        TAO_LIMIT = _taoLimit;
        ALPHA_LIMIT = _alphaLimit;
        ERC20_LIMIT = _erc20Limit;
        LIMIT_RESET_PERIOD = _limitResetPeriodMinutes * 60;
    }

    function setProposalExpirationBlocks(uint256 newExpirationBlocks) external onlyGovernance {
        proposalExpirationBlocks = newExpirationBlocks;
    }

    function _buildNativePayload(address recipient, uint256 amount) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = recipient;
        values[0] = amount;
        calldatas[0] = "";
    }

    function _buildERC20Payload(address token, address recipient, uint256 amount) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = token;
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount);
    }

    function _buildAlphaPayload(address target, uint16 netuid, bytes32 hotkey, address recipient, uint256 amount) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(IAlphaToken.transferAlpha.selector, netuid, hotkey, recipient, amount);
    }

    function propose(address[] memory, uint256[] memory, bytes[] memory, string memory)
    public
    override(Governor)
    returns (uint256)
    {
        revert("Use specific propose functions");
    }

    function _proposeAndVote(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256) {
        uint256 proposalId = hashProposal(targets, values, calldatas, keccak256(bytes(description)));

        if (proposalSnapshot(proposalId) == 0) {
            super.propose(targets, values, calldatas, description);
        } else {
            ProposalState currentState = state(proposalId);

            if (currentState == ProposalState.Active) {
                _castVote(proposalId, msg.sender, 1, "");
            } else if (currentState == ProposalState.Pending) {
                revert("Proposal exists but is Pending");
            } else {
                revert("Proposal exists but voting is closed");
            }
        }

        return proposalId;
    }

    function proposeNativeTransfer(address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildNativePayload(recipient, amount);
        return super.propose(targets, values, calldatas, description);
    }

    function proposeAndVoteNativeTransfer(address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildNativePayload(recipient, amount);
        return _proposeAndVote(targets, values, calldatas, description);
    }

    function proposeERC20Transfer(address token, address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildERC20Payload(token, recipient, amount);
        return super.propose(targets, values, calldatas, description);
    }

    function proposeAndVoteERC20Transfer(address token, address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildERC20Payload(token, recipient, amount);
        return _proposeAndVote(targets, values, calldatas, description);
    }

    function proposeAlphaTransfer(address target, uint16 netuid, bytes32 hotkey, address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildAlphaPayload(target, netuid, hotkey, recipient, amount);
        return super.propose(targets, values, calldatas, description);
    }

    function proposeAndVoteAlphaTransfer(address target, uint16 netuid, bytes32 hotkey, address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildAlphaPayload(target, netuid, hotkey, recipient, amount);
        return _proposeAndVote(targets, values, calldatas, description);
    }

    function queue(address[] memory, uint256[] memory, bytes[] memory, bytes32)
    public
    override(Governor)
    returns (uint256)
    {
        revert("Use specific queue functions");
    }

    function queueNativeTransfer(address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildNativePayload(recipient, amount);
        return super.queue(targets, values, calldatas, keccak256(bytes(description)));
    }

    function queueERC20Transfer(address token, address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildERC20Payload(token, recipient, amount);
        return super.queue(targets, values, calldatas, keccak256(bytes(description)));
    }

    function queueAlphaTransfer(address target, uint16 netuid, bytes32 hotkey, address recipient, uint256 amount, string memory description) external returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildAlphaPayload(target, netuid, hotkey, recipient, amount);
        return super.queue(targets, values, calldatas, keccak256(bytes(description)));
    }

    function execute(address[] memory, uint256[] memory, bytes[] memory, bytes32)
    public
    payable
    override(Governor)
    returns (uint256)
    {
        revert("Use specific execute functions");
    }

    function executeNativeTransfer(address recipient, uint256 amount, string memory description) external payable returns (uint256) {
        _updateLimit(bytes32(0), amount, TAO_LIMIT);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildNativePayload(recipient, amount);
        return super.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function executeERC20Transfer(address token, address recipient, uint256 amount, string memory description) external payable returns (uint256) {
        _updateLimit(bytes32(uint256(uint160(token))), amount, ERC20_LIMIT);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildERC20Payload(token, recipient, amount);
        return super.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function executeAlphaTransfer(address target, uint16 netuid, bytes32 hotkey, address recipient, uint256 amount, string memory description) external payable returns (uint256) {
        _updateLimit(keccak256(abi.encode(target, netuid)), amount, ALPHA_LIMIT);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _buildAlphaPayload(target, netuid, hotkey, recipient, amount);
        return super.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function _updateLimit(bytes32 assetId, uint256 amount, uint256 limit) internal {
        uint256 currentPeriod = block.timestamp / LIMIT_RESET_PERIOD;
        require(periodSpent[currentPeriod][assetId] + amount <= limit, "Limit exceeded");
        periodSpent[currentPeriod][assetId] += amount;
    }

    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        bytes32 hotkey = getHotkeyForAddress(account);
        return _proposalTallies[proposalId].hotkeySupport[hotkey] != 0;
    }

    function getUidForAddress(address evmAddress) public view returns (uint16) {
        LookupItem[] memory items = IUidLookup(UID_LOOKUP_ADDRESS).uidLookup(TARGET_NETUID, evmAddress, 1);
        require(items.length > 0, "No UID");
        return items[0].uid;
    }

    function getHotkeyForAddress(address evmAddress) public view returns (bytes32) {
        uint16 uid = getUidForAddress(evmAddress);
        return IMetagraph(METAGRAPH_ADDRESS).getHotkey(TARGET_NETUID, uid);
    }

    function getVotingPowerForAddress(address evmAddress) public view returns (uint256) {
        bytes32 hotkey = getHotkeyForAddress(evmAddress);
        return IBittensorVotes(BITTENSOR_VOTES_ADDRESS).getVotingPower(TARGET_NETUID, hotkey);
    }

    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason)
    internal
    virtual
    override
    onlyValidator(account)
    returns (uint256)
    {
        return super._castVote(proposalId, account, support, reason);
    }

    function _getVotes(address account, uint256, bytes memory) internal view virtual override returns (uint256) {
        return getVotingPowerForAddress(account);
    }

    function quorum(uint256) public view virtual override returns (uint256) {
        return (IBittensorVotes(BITTENSOR_VOTES_ADDRESS).getTotalVotingPower(TARGET_NETUID) * SUPPORT_THRESHOLD_NUMERATOR) / 10000;
    }

    function _countVote(uint256 proposalId, address account, uint8 support, uint256, bytes memory)
    internal
    virtual
    override
    {
        ProposalTallies storage tally = _proposalTallies[proposalId];
        require(support <= 1, "Invalid vote");

        bytes32 hotkey = getHotkeyForAddress(account);

        if (tally.hotkeySupport[hotkey] == 0) {
            tally.votedHotkeys.push(hotkey);
        }
        tally.hotkeySupport[hotkey] = support + 1;
    }

    function _getTallyResult(uint256 proposalId) internal view returns (uint256 forVotes, uint256 againstVotes) {
        ProposalTallies storage tally = _proposalTallies[proposalId];
        for (uint256 i = 0; i < tally.votedHotkeys.length; i++) {
            bytes32 hotkey = tally.votedHotkeys[i];
            uint256 weight = IBittensorVotes(BITTENSOR_VOTES_ADDRESS).getVotingPower(TARGET_NETUID, hotkey);
            uint8 support = tally.hotkeySupport[hotkey];
            if (support == 2) forVotes += weight;
            else if (support == 1) againstVotes += weight;
        }
    }

    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        (uint256 forVotes, ) = _getTallyResult(proposalId);
        return forVotes >= quorum(proposalSnapshot(proposalId));
    }

    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        (uint256 forVotes, ) = _getTallyResult(proposalId);
        return forVotes >= quorum(proposalSnapshot(proposalId));
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        ProposalState currentState = super.state(proposalId);
        if (currentState == ProposalState.Succeeded) {
            if (block.number > proposalDeadline(proposalId) + proposalExpirationBlocks) {
                return ProposalState.Expired;
            }
        }
        return currentState;
    }

    function clock() public view virtual override returns (uint48) { return uint48(block.number); }
    function CLOCK_MODE() public view virtual override returns (string memory) { return "mode=blocknumber&from=default"; }
    function COUNTING_MODE() public pure virtual override returns (string memory) { return "support=bravo&quorum=for,against"; }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) { return super.votingDelay(); }
    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) { return super.votingPeriod(); }
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) { return super.proposalThreshold(); }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}