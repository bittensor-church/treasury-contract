// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bittensor voting power (EMA) precompile interface
interface IBittensorVotes {
    /// @notice Returns voting power of a hotkey on a subnet
    /// @param netuid Bittensor subnet network ID
    /// @param hotkey Hotkey as bytes32 (public key)
    function getVotingPower(uint16 netuid, bytes32 hotkey)
    external
    view
    returns (uint256);

    /// @notice Whether EMA voting power tracking is enabled for this subnet
    /// @param netuid Network ID
    function isVotingPowerTrackingEnabled(uint16 netuid)
    external
    view
    returns (bool);

    /// @notice Block at which voting power tracking will be disabled
    /// @param netuid Network ID
    function getVotingPowerDisableAtBlock(uint16 netuid)
    external
    view
    returns (uint64);

    /// @notice EMA alpha parameter for voting power calculation
    /// @param netuid Network ID
    function getVotingPowerEmaAlpha(uint16 netuid)
    external
    view
    returns (uint64);
}