// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

struct LookupItem {
    uint16 uid;
    uint64 block_associated;
}

interface IUidLookup {
    function uidLookup(
        uint16 netuid,
        address evm_address,
        uint16 limit
    ) external view returns (LookupItem[] memory);
}

interface IMetagraph {
    function getValidatorStatus(uint16 netuid, uint16 uid) external view returns (bool);
}

interface IBittensorVotes {
    function getVotingPower(uint16 netuid, bytes32 hotkey) external view returns (uint256);
    function getTotalVotingPower(uint16 netuid) external view returns (uint256);
}

contract TreasuryController is Governor, GovernorSettings, GovernorTimelockControl {
    IBittensorVotes public immutable BITTENSOR_VOTES;
    uint16 public immutable TARGET_NETUID;
    uint256 public immutable QUORUM_NUMERATOR;
    uint256 public proposalExpirationBlocks;

    address constant METAGRAPH_ADDRESS = 0x0000000000000000000000000000000000000802;
    address constant UID_LOOKUP_ADDRESS = 0x0000000000000000000000000000000000000806;

    struct ProposalTallies {
        address[] voters;
        mapping(address => uint8) support;
        bool counted;
        uint256 forVotes;
        uint256 againstVotes;
    }

    mapping(uint256 => ProposalTallies) private _proposalTallies;

    constructor(
        TimelockController _timelock,
        address _bittensorVotes,
        uint16 _netuid,
        string memory _name,
        uint48 _initialVotingDelay,
        uint32 _initialVotingPeriod,
        uint256 _initialProposalThreshold,
        uint256 _quorumNumerator,
        uint256 _proposalExpirationBlocks
    )
    Governor(_name)
    GovernorSettings(_initialVotingDelay, _initialVotingPeriod, _initialProposalThreshold)
    GovernorTimelockControl(_timelock)
    {
        BITTENSOR_VOTES = IBittensorVotes(_bittensorVotes);
        TARGET_NETUID = _netuid;
        QUORUM_NUMERATOR = _quorumNumerator;
        proposalExpirationBlocks = _proposalExpirationBlocks;
    }

    function setProposalExpirationBlocks(uint256 newExpirationBlocks) external onlyGovernance {
        proposalExpirationBlocks = newExpirationBlocks;
    }

    function clock() public view virtual override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "support=bravo&quorum=for,against";
    }

    function proposeAndVote(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256) {
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

    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalTallies[proposalId].support[account] != 0;
    }

    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason
    ) internal virtual override returns (uint256) {
        LookupItem[] memory items = IUidLookup(UID_LOOKUP_ADDRESS).uidLookup(TARGET_NETUID, account, 1);

        require(items.length > 0, "No UID associated with address");
        require(IMetagraph(METAGRAPH_ADDRESS).getValidatorStatus(TARGET_NETUID, items[0].uid), "Not a validator");

        return super._castVote(proposalId, account, support, reason);
    }

    function _getVotes(
        address account,
        uint256,
        bytes memory
    )
    internal
    view
    virtual
    override
    returns (uint256)
    {
        return BITTENSOR_VOTES.getVotingPower(TARGET_NETUID, bytes32(uint256(uint160(account))));
    }

    function quorum(
        uint256
    )
    public
    view
    virtual
    override
    returns (uint256)
    {
        return (BITTENSOR_VOTES.getTotalVotingPower(TARGET_NETUID) * QUORUM_NUMERATOR) / 10000;
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256,
        bytes memory
    )
    internal
    virtual
    override
    {
        ProposalTallies storage tally = _proposalTallies[proposalId];
        require(support <= 1, "Invalid vote type");

        if (tally.support[account] == 0) {
            tally.voters.push(account);
        }
        tally.support[account] = support + 1;
    }

    function _getTallyResult(uint256 proposalId) internal view returns (uint256 forVotes, uint256 againstVotes) {
        ProposalTallies storage tally = _proposalTallies[proposalId];

        for (uint256 i = 0; i < tally.voters.length; i++) {
            address voter = tally.voters[i];
            uint256 weight = _getVotes(voter, 0, "");

            if (tally.support[voter] == 2) forVotes += weight;
            else if (tally.support[voter] == 1) againstVotes += weight;
        }
    }

    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        (uint256 forVotes, uint256 againstVotes) = _getTallyResult(proposalId);
        return quorum(proposalSnapshot(proposalId)) <= (forVotes + againstVotes);
    }

    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        (uint256 forVotes, uint256 againstVotes) = _getTallyResult(proposalId);
        return forVotes > againstVotes;
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

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function proposalNeedsQueuing(uint256 proposalId)
    public
    view
    override(Governor, GovernorTimelockControl)
    returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}