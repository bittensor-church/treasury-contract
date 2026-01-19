// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;

contract TreasuryVault is TimelockController {

    error NeuronRegistrationFailed();
    error RefundError();

    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}

    function registerNeuron(
        uint16 netuid,
        bytes32 hotkey
    ) external payable returns (bool) {
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("burnedRegister(uint16,bytes32)")),
            netuid,
            hotkey
        );

        uint256 balanceBefore = address(this).balance;

        (bool success, ) = NEURON_PRECOMPILE.call{value: 0, gas: gasleft()}(
            data
        );

        if (!success) {
            revert NeuronRegistrationFailed();
        }

        uint256 balanceAfter = address(this).balance;
        uint256 burnedAmount = balanceBefore - balanceAfter;

        if (msg.value > burnedAmount) {
            _processRefund(msg.sender, msg.value - burnedAmount);
        }

        emit NeuronRegistration(netuid, hotkey, msg.sender);
        return true;
    }


    function _processRefund(address recipient, uint256 amount) private {
        if (amount > 0) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) {
                revert RefundError();
            }
        }
    }
}