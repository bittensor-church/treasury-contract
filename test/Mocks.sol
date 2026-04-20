// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TreasuryVault } from "../src/vault/TreasuryVault.sol";
import {
    IBittensorVotes,
    IUidLookup,
    IMetagraph,
    LookupItem,
    IStakingV2
} from "../src/controller/TreasuryController.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface Vm {
    function deal(address who, uint256 newBalance) external;
}

contract MockNeuron {
    address constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm constant vm = Vm(VM_ADDRESS);

    bool public shouldFail;
    mapping(uint16 => uint64) public burnCosts;

    function registerLimit(uint16 netuid, bytes32, uint64 limitPrice) external payable {
        if (shouldFail) {
            revert("Mock: registerLimit failed");
        }

        uint256 burn = burnCosts[netuid];
        uint256 limitInWei = uint256(limitPrice) * 1e9;
        if (burn > limitInWei) {
            revert("Mock: burn exceeds limit");
        }

        if (burn > 0) {
            if (msg.sender.balance < burn) {
                revert("Mock: burn exceeds caller balance");
            }
            vm.deal(msg.sender, msg.sender.balance - burn);
            vm.deal(address(this), address(this).balance + burn);
        }
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setBurnCost(uint16 netuid, uint64 cost) external {
        burnCosts[netuid] = cost;
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
    receive() external payable { }
    fallback() external payable { }

    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract MockUidLookup is IUidLookup {
    mapping(uint16 => mapping(address => LookupItem[])) public lookups;

    function setLookup(uint16 netuid, address addr, uint16 uid) external {
        delete lookups[netuid][addr];
        lookups[netuid][addr].push(LookupItem({ uid: uid, block_associated: uint64(block.number) }));
    }

    function addLookup(uint16 netuid, address addr, uint16 uid) external {
        lookups[netuid][addr].push(LookupItem({ uid: uid, block_associated: uint64(block.number) }));
    }

    function uidLookup(uint16 netuid, address evm_address, uint16)
        external
        view
        override
        returns (LookupItem[] memory)
    {
        return lookups[netuid][evm_address];
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

contract MockERC20 is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

    contract MockStakingV2 is IStakingV2 {
        event StakeTransferred(
            bytes32 destinationColdkey,
            bytes32 hotkey,
            uint256 originNetuid,
            uint256 destinationNetuid,
            uint256 amountAlpha
        );

        function transferStake(
            bytes32 destinationColdkey,
            bytes32 hotkey,
            uint256 originNetuid,
            uint256 destinationNetuid,
            uint256 amountAlpha
        ) external {
            emit StakeTransferred(destinationColdkey, hotkey, originNetuid, destinationNetuid, amountAlpha);
        }
    }
