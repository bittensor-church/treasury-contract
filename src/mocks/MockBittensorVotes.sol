// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ZMIANA: Named import
import { IBittensorVotes } from "../interfaces/IBittensorVotes.sol";

contract MockBittensorVotes is IBittensorVotes {
    mapping(bytes32 => uint256) public votingPower;

    function setVotingPower(uint16 /* netuid */, bytes32 hotkey, uint256 amount) external {
        votingPower[hotkey] = amount;
    }

    function getVotingPower(uint16 /* netuid */, bytes32 hotkey) external view override returns (uint256) {
        return votingPower[hotkey];
    }

    function isVotingPowerTrackingEnabled(uint16) external pure override returns (bool) { return true; }
    function getVotingPowerDisableAtBlock(uint16) external pure override returns (uint64) { return 0; }
    function getVotingPowerEmaAlpha(uint16) external pure override returns (uint64) { return 0; }
}