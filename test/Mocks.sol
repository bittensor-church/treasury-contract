// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TreasuryVault } from "../src/vault/TreasuryVault.sol";
import { IBittensorVotes, IUidLookup, IMetagraph, LookupItem } from "../src/controller/TreasuryController.sol";

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

contract MockBittensorVotes is IBittensorVotes {
    mapping(uint16 => mapping(bytes32 => uint256)) public votingPower;
    mapping(uint16 => uint256) public totalVotingPower;

    function setVotingPower(uint16 netuid, bytes32 hotkey, uint256 amount) external {
        votingPower[netuid][hotkey] = amount;
    }

    function setTotalVotingPower(uint16 netuid, uint256 amount) external {
        totalVotingPower[netuid] = amount;
    }

    function getVotingPower(uint16 netuid, bytes32 hotkey) external view override returns (uint256) {
        return votingPower[netuid][hotkey];
    }

    function getTotalVotingPower(uint16 netuid) external view override returns (uint256) {
        return totalVotingPower[netuid];
    }
}

contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract MockUidLookup is IUidLookup {
    mapping(uint16 => mapping(address => LookupItem)) public lookups;
    bool public exists;

    function setLookup(uint16 netuid, address addr, uint16 uid) external {
        lookups[netuid][addr] = LookupItem({
            uid: uid,
            block_associated: uint64(block.number)
        });
        exists = true;
    }

    function clearLookup() external {
        exists = false;
    }

    function uidLookup(
        uint16 netuid,
        address evm_address,
        uint16
    ) external view override returns (LookupItem[] memory) {
        LookupItem[] memory items;
        if (exists && lookups[netuid][evm_address].block_associated != 0) {
            items = new LookupItem[](1);
            items[0] = lookups[netuid][evm_address];
        } else {
            items = new LookupItem[](0);
        }
        return items;
    }
}

contract MockMetagraph is IMetagraph {
    mapping(uint16 => mapping(uint16 => bool)) public validators;
    mapping(uint16 => mapping(uint16 => bytes32)) public hotkeys;

    function setValidatorStatus(uint16 netuid, uint16 uid, bool status) external {
        validators[netuid][uid] = status;
    }

    function setHotkey(uint16 netuid, uint16 uid, bytes32 hotkey) external {
        hotkeys[netuid][uid] = hotkey;
    }

    function getValidatorStatus(uint16 netuid, uint16 uid) external view override returns (bool) {
        return validators[netuid][uid];
    }

    function getHotkey(uint16 netuid, uint16 uid) external view override returns (bytes32) {
        return hotkeys[netuid][uid];
    }
}

contract MockRegistrationCost {
    mapping(uint16 => uint256) public burnCosts;
    mapping(uint16 => bool) public registrationAllowed;

    function setBurn(uint16 netuid, uint256 amount) external {
        burnCosts[netuid] = amount;
    }

    function setRegistrationAllowed(uint16 netuid, bool allowed) external {
        registrationAllowed[netuid] = allowed;
    }

    function getBurn(uint16 netuid) external view returns (uint256) {
        return burnCosts[netuid];
    }

    function isRegistrationAllowed(uint16 netuid) external view returns (bool) {
        return registrationAllowed[netuid];
    }
}