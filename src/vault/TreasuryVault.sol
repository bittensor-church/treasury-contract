// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

/// @dev Adres prekompilatu Stakingu w sieci Bittensor.
address constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000805;

/// @dev Adres prekompilatu Rejestracji Neurona.
address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;

interface IStaking {
    // Potrzebne do wewnętrznego wywołania w transferAlpha
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external;
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external;
}

contract TreasuryVault is TimelockController {

    // Błędy
    error StakeError();
    error RemoveStakeError();
    error NeuronRegistrationFailed();
    error RefundError();

    // Eventy
    event StakeRemoved(bytes32 indexed hotkey, uint256 amount, uint256 netuid);
    event AlphaTransferred(bytes32 indexed fromValidator, bytes32 indexed toValidator, uint256 amount, uint256 netuid);
    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    )
    TimelockController(minDelay, proposers, executors, admin)
    {}

    // receive() usunięte - jest w TimelockController

    /// @notice Zabezpieczenie: funkcja może być wywołana tylko przez ten kontrakt (Timelock/DAO).
    modifier onlySelf() {
        require(msg.sender == address(this), "Only Timelock can execute this");
        _;
    }

    /// @notice Funkcja pomocnicza do zwrotu reszty.
    function _processRefund(address recipient, uint256 amount) private {
        if (amount > 0) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) {
                revert RefundError();
            }
        }
    }

    // --- Core Logic: Zarządzanie Alfami (Stake) ---

    // BRAK addStake (usunięte zgodnie z życzeniem)

    /// @notice Usuwa stake (Alpha -> Tao) od konkretnego walidatora.
    /// @dev TAO wraca na balans Vaulta. Wymaga głosowania DAO (onlySelf).
    function removeStake(
        bytes32 hotkey,
        uint256 amount,
        uint256 netuid
    ) external onlySelf {
        bytes memory data = abi.encodeWithSelector(
            IStaking.removeStake.selector,
            hotkey,
            amount,
            netuid
        );

        (bool success, ) = STAKING_PRECOMPILE.call(data);
        if (!success) {
            revert RemoveStakeError();
        }

        emit StakeRemoved(hotkey, amount, netuid);
    }

    /// @notice Przesyła "Alfy" (Stake) z jednego walidatora na drugiego.
    /// @dev Wykonuje atomowy unstake + stake. Wymaga głosowania DAO (onlySelf).
    function transferAlpha(
        bytes32 fromValidator,
        bytes32 toValidator,
        uint256 amount,
        uint256 netuid
    ) external onlySelf {
        // 1. Unstake
        bytes memory unstakeData = abi.encodeWithSelector(
            IStaking.removeStake.selector,
            fromValidator,
            amount,
            netuid
        );
        (bool successUnstake, ) = STAKING_PRECOMPILE.call(unstakeData);
        if (!successUnstake) {
            revert RemoveStakeError();
        }

        // 2. Stake
        bytes memory stakeData = abi.encodeWithSelector(
            IStaking.addStake.selector,
            toValidator,
            amount,
            netuid
        );
        (bool successStake, ) = STAKING_PRECOMPILE.call(stakeData);
        if (!successStake) {
            revert StakeError();
        }

        emit AlphaTransferred(fromValidator, toValidator, amount, netuid);
    }

    // --- Neuron Registration ---

    /// @notice Rejestruje Vault jako neuron.
    /// @dev Reszta (nadmiar) TAO jest zwracana do msg.sender.
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
}