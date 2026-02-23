// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;
address constant REGISTRATION_COST_PRECOMPILE = 0x000000000000000000000000000000000000080e;

interface IRegistrationCost {
    function getBurn(uint16 netuid) external view returns (uint256);
    function isRegistrationAllowed(uint16 netuid) external view returns (bool);
}

contract TreasuryVault is TimelockController {
    error NeuronRegistrationFailed();
    error RefundError();
    error InsufficientTaoForRegistration(uint256 required, uint256 provided);
    error RegistrationNotAllowed(uint16 netuid);

    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    { }

    function getRegistrationCost(uint16 netuid) public view returns (uint256) {
        return IRegistrationCost(REGISTRATION_COST_PRECOMPILE).getBurn(netuid);
    }

    function isRegistrationAllowed(uint16 netuid) public view returns (bool) {
        return IRegistrationCost(REGISTRATION_COST_PRECOMPILE).isRegistrationAllowed(netuid);
    }

    function registerNeuron(uint16 netuid, bytes32 hotkey) external payable returns (bool) {
        if (!isRegistrationAllowed(netuid)) {
            revert RegistrationNotAllowed(netuid);
        }

        uint256 burnCost = getRegistrationCost(netuid);
        if (msg.value < burnCost) {
            revert InsufficientTaoForRegistration(burnCost, msg.value);
        }

        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("burnedRegister(uint16,bytes32)")), netuid, hotkey);

        uint256 balanceBefore = address(this).balance;

        (bool success,) = NEURON_PRECOMPILE.call{ value: 0, gas: gasleft() }(data);

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
            (bool success,) = payable(recipient).call{ value: amount }("");
            if (!success) {
                revert RefundError();
            }
        }
    }
}

