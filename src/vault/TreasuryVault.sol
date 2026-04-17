// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;

interface INeuron {
    function registerLimit(uint16 netuid, bytes32 hotkey, uint64 limitPrice) external payable;
}

contract TreasuryVault is TimelockController {
    error NeuronRegistrationFailed();
    error RefundError();
    error LimitPriceOverflow();

    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    { }

    function registerNeuron(uint16 netuid, bytes32 hotkey) external payable returns (bool) {
        uint256 limitRao = msg.value / 1e9;
        if (limitRao > type(uint64).max) {
            revert LimitPriceOverflow();
        }
        uint64 limitPrice = uint64(limitRao);

        uint256 balanceBefore = address(this).balance;

        try INeuron(NEURON_PRECOMPILE).registerLimit(netuid, hotkey, limitPrice) { }
        catch {
            revert NeuronRegistrationFailed();
        }

        uint256 consumed = balanceBefore - address(this).balance;
        uint256 refundAmount = msg.value - consumed;

        if (refundAmount > 0) {
            _processRefund(msg.sender, refundAmount);
        }

        emit NeuronRegistration(netuid, hotkey, msg.sender);
        return true;
    }

    function _processRefund(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{ value: amount }("");
        if (!success) {
            revert RefundError();
        }
    }
}
