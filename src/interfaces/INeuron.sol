// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INeuron {
    function burnedRegister(
        uint16 netuid,
        bytes32 hotkey
    ) external payable returns (bool);
}
