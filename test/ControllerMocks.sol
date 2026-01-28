// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IBittensorVotes } from "../src/interfaces/IBittensorVotes.sol";

contract MockBittensorVotes is IBittensorVotes {
    mapping(uint16 => mapping(bytes32 => uint256)) public votingPower;
    mapping(uint16 => uint256) public totalVotingPower;

    function setVotingPower(uint16 netuid, bytes32 hotkey, uint256 amount) external {
        votingPower[netuid][hotkey] = amount;
    }

    function setTotalVotingPower(uint16 netuid, uint256 amount) external {
        totalVotingPower[netuid] = amount;
    }

    function getVotingPower(uint16 netuid, bytes32 hotkey) external view override returns (uint256) {
        return votingPower[netuid][hotkey];
    }

    function getTotalVotingPower(uint16 netuid) external view override returns (uint256) {
        return totalVotingPower[netuid];
    }

    function isVotingPowerTrackingEnabled(uint16) external pure override returns (bool) {
        return true;
    }

    function getVotingPowerDisableAtBlock(uint16) external pure override returns (uint64) {
        return 0;
    }

    function getVotingPowerEmaAlpha(uint16) external pure override returns (uint64) {
        return 0;
    }
}

contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}
