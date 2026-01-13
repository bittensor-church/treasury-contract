// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBittensorVotes.sol";

contract MockBittensorVotes is IBittensorVotes {
    mapping(uint16 => mapping(bytes32 => uint256)) public votingPower;
    mapping(uint16 => uint256) public totalVotingPower;
    mapping(uint16 => bool) public trackingEnabled;
    mapping(uint16 => uint64) public disableAtBlock;
    mapping(uint16 => uint64) public emaAlpha;

    function setVotingPower(uint16 netuid, bytes32 hotkey, uint256 amount) external {
        votingPower[netuid][hotkey] = amount;
    }

    function setTotalVotingPower(uint16 netuid, uint256 amount) external {
        totalVotingPower[netuid] = amount;
    }

    function setTrackingEnabled(uint16 netuid, bool enabled) external {
        trackingEnabled[netuid] = enabled;
    }

    function setDisableAtBlock(uint16 netuid, uint64 blockNum) external {
        disableAtBlock[netuid] = blockNum;
    }

    function setEmaAlpha(uint16 netuid, uint64 alpha) external {
        emaAlpha[netuid] = alpha;
    }

    function getVotingPower(uint16 netuid, bytes32 hotkey) external view override returns (uint256) {
        return votingPower[netuid][hotkey];
    }

    function getTotalVotingPower(uint16 netuid) external view override returns (uint256) {
        return totalVotingPower[netuid];
    }

    function isVotingPowerTrackingEnabled(uint16 netuid) external view override returns (bool) {
        return trackingEnabled[netuid];
    }

    function getVotingPowerDisableAtBlock(uint16 netuid) external view override returns (uint64) {
        return disableAtBlock[netuid];
    }

    function getVotingPowerEmaAlpha(uint16 netuid) external view override returns (uint64) {
        return emaAlpha[netuid];
    }
}