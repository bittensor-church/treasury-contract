// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IBittensorVotes } from "../interfaces/IBittensorVotes.sol";

contract TreasuryController is
    Governor,
    GovernorSettings,
    GovernorTimelockControl
{
    IBittensorVotes public immutable BITTENSOR_VOTES;
    uint16 public immutable TARGET_NETUID;

    uint256 public immutable QUORUM_NUMERATOR;

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
        uint256 _quorumNumerator
    )
    Governor(_name)
    GovernorSettings(_initialVotingDelay, _initialVotingPeriod, _initialProposalThreshold)
    GovernorTimelockControl(_timelock)
    {
        BITTENSOR_VOTES = IBittensorVotes(_bittensorVotes);
        TARGET_NETUID = _netuid;
        QUORUM_NUMERATOR = _quorumNumerator;
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

    function hasVoted(uint256 proposalId, address account) public view virtual override returns (bool) {
        return _proposalTallies[proposalId].support[account] != 0;
    }

    function _getVotes(
        address account,
        uint256 /*timepoint*/,
        bytes memory /*params*/
    ) internal view virtual override returns (uint256) {
        return BITTENSOR_VOTES.getVotingPower(TARGET_NETUID, bytes32(uint256(uint160(account))));
    }

    function quorum(uint256 /* timepoint */) public view virtual override returns (uint256) {
        return (BITTENSOR_VOTES.getTotalVotingPower(TARGET_NETUID) * QUORUM_NUMERATOR) / 10000;
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 /*weight*/,
        bytes memory /*params*/
    ) internal virtual override {
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
            uint256 weight = BITTENSOR_VOTES.getVotingPower(TARGET_NETUID, bytes32(uint256(uint160(voter))));

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
        return super.state(proposalId);
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