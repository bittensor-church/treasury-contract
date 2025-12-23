// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/openzeppelin-contracts/contracts/governance/Governor.sol";
import "lib/openzeppelin-contracts/contracts/governance/extensions/GovernorSettings.sol";
import "lib/openzeppelin-contracts/contracts/governance/extensions/GovernorCountingSimple.sol";
import "lib/openzeppelin-contracts/contracts/governance/extensions/GovernorVotes.sol";
import "lib/openzeppelin-contracts/contracts/governance/extensions/GovernorVotesQuorumFraction.sol"; // NOWY IMPORT
import "lib/openzeppelin-contracts/contracts/governance/extensions/GovernorTimelockControl.sol";
import "../interfaces/IBittensorVotes.sol";

contract TreasuryController is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction, // NOWE DZIEDZICZENIE
    GovernorTimelockControl
{
    IBittensorVotes public immutable bittensorVotes;
    uint16 public immutable targetNetuid;

    constructor(
        IVotes _token,
        TimelockController _timelock,
        address _bittensorVotes,
        uint16 _netuid
    )
    Governor("BittensorDAO")
    GovernorSettings(1 days, 5 days, 100e9)
    GovernorVotes(_token)
    GovernorVotesQuorumFraction(4) // Ustawiamy Quorum na 4%
    GovernorTimelockControl(_timelock)
    {
        bittensorVotes = IBittensorVotes(_bittensorVotes);
        targetNetuid = _netuid;
    }

    // Override dla getVotes (logika Bittensor)
    function _getVotes(
        address account,
        uint256 timepoint,
        bytes memory params
    ) internal view override(Governor, GovernorVotes) returns (uint256) {
        return bittensorVotes.getVotingPower(targetNetuid, bytes32(uint256(uint160(account))));
    }

    // --- Boilerplate overrides wymagane przez Solidity ---

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(blockNumber);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    internal
    override(Governor, GovernorTimelockControl)
    returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    internal
    override(Governor, GovernorTimelockControl)
    {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    internal
    override(Governor, GovernorTimelockControl)
    returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}