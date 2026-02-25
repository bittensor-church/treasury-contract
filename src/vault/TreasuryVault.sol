// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;

interface INeuron {
    function getBurnCost(uint16 netuid) external view returns (uint64);
    function burnedRegister(uint16 netuid, bytes32 hotkey) external payable;
}

contract TreasuryVault is TimelockController {
    error NeuronRegistrationFailed();
    error RefundError();
    error InsufficientTaoForRegistration(uint256 required, uint256 provided);

    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    { }

    function getRegistrationCost(uint16 netuid) public view returns (uint256) {
        return uint256(INeuron(NEURON_PRECOMPILE).getBurnCost(netuid));
    }

    function registerNeuron(uint16 netuid, bytes32 hotkey) external payable returns (bool) {
        uint256 burnCost = getRegistrationCost(netuid);

        if (msg.value < burnCost) {
            revert InsufficientTaoForRegistration(burnCost, msg.value);
        }

        try INeuron(NEURON_PRECOMPILE).burnedRegister{ value: burnCost }(netuid, hotkey) { }
        catch {
            revert NeuronRegistrationFailed();
        }

        uint256 refundAmount = msg.value - burnCost;

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
