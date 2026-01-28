// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TreasuryVault } from "../src/vault/TreasuryVault.sol";

interface Vm {
    function deal(address who, uint256 newBalance) external;
}

contract MockNeuron {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bool public shouldFail;
    uint256 public burnAmount;
    uint256 public mintAmount;

    function burnedRegister(uint16, bytes32) external payable {
        if (shouldFail) {
            revert("Mock: burnedRegister failed");
        }

        if (burnAmount > 0) {
            if (msg.sender.balance >= burnAmount) {
                vm.deal(msg.sender, msg.sender.balance - burnAmount);
            } else {
                vm.deal(msg.sender, 0);
            }
        }

        if (mintAmount > 0) {
            vm.deal(msg.sender, msg.sender.balance + mintAmount);
        }
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setBurnAmount(uint256 _amount) external {
        burnAmount = _amount;
        mintAmount = 0;
    }

    function setMintAmount(uint256 _amount) external {
        mintAmount = _amount;
        burnAmount = 0;
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("I refuse refunds");
    }

    function callRegister(address _target, uint16 _netuid, bytes32 _hotkey) external payable {
        TreasuryVault(payable(_target)).registerNeuron{ value: msg.value }(_netuid, _hotkey);
    }
}
