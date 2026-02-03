// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

// ============ Precompile Addresses ============
address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;
address constant REGISTRATION_COST_PRECOMPILE = 0x000000000000000000000000000000000000080e;

// ============ Precompile Interfaces ============

interface IRegistrationCost {
    function getBurn(uint16 netuid) external view returns (uint256);
    function isRegistrationAllowed(uint16 netuid) external view returns (bool);
}

// ============ Treasury Vault Contract ============

contract TreasuryVault is TimelockController {
    // ============ Errors ============
    error NeuronRegistrationFailed();
    error RefundError();
    error InsufficientTaoForRegistration(uint256 required, uint256 provided);
    error RegistrationNotAllowed(uint16 netuid);

    // ============ Events ============
    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    // ============ Constructor ============
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    { }

    // ============ Registration Cost Functions ============

    /**
     * @notice Returns the current burn cost to register a neuron on a subnet
     * @param netuid The subnet ID
     * @return The burn cost in RAO (1 TAO = 10^9 RAO)
     */
    function getRegistrationCost(uint16 netuid) public view returns (uint256) {
        return IRegistrationCost(REGISTRATION_COST_PRECOMPILE).getBurn(netuid);
    }

    /**
     * @notice Checks if registration is allowed on a subnet
     * @param netuid The subnet ID
     * @return True if registration is allowed
     */
    function isRegistrationAllowed(uint16 netuid) public view returns (bool) {
        return IRegistrationCost(REGISTRATION_COST_PRECOMPILE).isRegistrationAllowed(netuid);
    }

    // ============ Neuron Registration ============

    /**
     * @notice Register a neuron on a subnet with burn registration
     * @dev Validates registration cost before proceeding. Refunds excess TAO.
     * @param netuid The subnet ID
     * @param hotkey The hotkey to register (bytes32)
     */
    function registerNeuron(uint16 netuid, bytes32 hotkey) external payable returns (bool) {
        // Check if registration is allowed
        if (!isRegistrationAllowed(netuid)) {
            revert RegistrationNotAllowed(netuid);
        }

        // Check if sufficient TAO is provided for registration
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

    // ============ Internal Functions ============

    function _processRefund(address recipient, uint256 amount) private {
        if (amount > 0) {
            (bool success,) = payable(recipient).call{ value: amount }("");
            if (!success) {
                revert RefundError();
            }
        }
    }
}

