// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBittensorVotes.sol";

/// @title MockBittensorVotes
/// @notice Mock contract to simulate EMA stake voting power
contract MockBittensorVotes is IBittensorVotes {
    mapping(bytes32 => uint256) public votingPower;
    mapping(uint16 => bool) public trackingEnabled;

    function setVotingPower(uint16 netuid, bytes32 hotkey, uint256 amount) external {
        votingPower[hotkey] = amount;
        trackingEnabled[netuid] = true;
    }

    function getVotingPower(uint16 netuid, bytes32 hotkey)
    external
    view
    override
    returns (uint256)
    {
        return votingPower[hotkey];
    }

    function isVotingPowerTrackingEnabled(uint16 netuid)
    external
    view
    override
    returns (bool)
    {
        return trackingEnabled[netuid];
    }

    function getVotingPowerDisableAtBlock(uint16 netuid)
    external
    pure
    override
    returns (uint64)
    {
        return 0;
    }

    function getVotingPowerEmaAlpha(uint16 netuid)
    external
    pure
    override
    returns (uint64)
    {
        return 0;
    }
}
