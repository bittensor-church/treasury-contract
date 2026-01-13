// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

address constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000805;
address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;

interface IStaking {
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external;
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external;
}

contract TreasuryVault is TimelockController {

    error StakeError();
    error RemoveStakeError();
    error NeuronRegistrationFailed();
    error RefundError();

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

    modifier onlySelf() {
        require(msg.sender == address(this), "Only Timelock can execute this");
        _;
    }

    function _processRefund(address recipient, uint256 amount) private {
        if (amount > 0) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) {
                revert RefundError();
            }
        }
    }

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

    function transferAlpha(
        bytes32 fromValidator,
        bytes32 toValidator,
        uint256 amount,
        uint256 netuid
    ) external onlySelf {
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