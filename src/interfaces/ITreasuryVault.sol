// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITreasuryVault {
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external;
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external;
    function moveStake(bytes32 fromHotkey, bytes32 toHotkey, uint256 amount, uint256 netuid) external;
    function registerNeuron(uint16 netuid, bytes32 hotkey) external payable returns (bool);
}