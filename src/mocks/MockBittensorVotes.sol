// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IBittensorVotes.sol";

/// @title MockBittensorVotes
/// @notice Mock contract to simulate EMA stake voting power
contract MockBittensorVotes is IBittensorVotes {
    mapping(bytes32 => uint256) public votingPower;
    mapping(uint16 => bool) public trackingEnabled;

    // --- FIX: TO JEST TA KLUCZOWA ZMIANA ---
    // Governor potrzebuje tej funkcji do obliczenia Quorum (4%).
    // Zwracamy 100,000 TAO. Ty masz 10,000 głosów (10%), więc > 4% i propozycja przejdzie.
    function getPastTotalSupply(uint256 /* timepoint */) external pure returns (uint256) {
        return 100_000 * 1e9; // 100,000 TAO (w jednostkach RAO)
    }
    // ----------------------------------------

    function setVotingPower(uint16 netuid, bytes32 hotkey, uint256 amount) external {
        votingPower[hotkey] = amount;
        trackingEnabled[netuid] = true;
    }

    function getVotingPower(uint16 /* netuid */, bytes32 hotkey)
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

    function getVotingPowerDisableAtBlock(uint16 /* netuid */)
    external
    pure
    override
    returns (uint64)
    {
        return 0;
    }

    function getVotingPowerEmaAlpha(uint16 /* netuid */)
    external
    pure
    override
    returns (uint64)
    {
        return 0;
    }
}