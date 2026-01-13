// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Bittensor voting power (EMA) precompile interface
interface IBittensorVotes {
    /// @notice Returns voting power of a hotkey on a subnet
    function getVotingPower(uint16 netuid, bytes32 hotkey) external view returns (uint256);

    /// @notice Returns total voting power on a subnet
    function getTotalVotingPower(uint16 netuid) external view returns (uint256);

    /// @notice Whether EMA voting power tracking is enabled for this subnet
    function isVotingPowerTrackingEnabled(uint16 netuid) external view returns (bool);

    /// @notice Block at which voting power tracking will be disabled
    function getVotingPowerDisableAtBlock(uint16 netuid) external view returns (uint64);

    /// @notice EMA alpha parameter for voting power calculation
    function getVotingPowerEmaAlpha(uint16 netuid) external view returns (uint64);
}