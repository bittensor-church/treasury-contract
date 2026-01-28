// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { TreasuryVault } from "../src/vault/TreasuryVault.sol";
import { MockNeuron, RevertingReceiver } from "./Mocks.sol";

contract TreasuryVaultTest is Test {
    TreasuryVault public vault;
    MockNeuron public neuronMock;
    RevertingReceiver public revertingReceiver;

    address constant NEURON_PRECOMPILE = 0x0000000000000000000000000000000000000804;

    address public admin = makeAddr("admin");
    address public proposer = makeAddr("proposer");
    address public executor = makeAddr("executor");
    address public user = makeAddr("user");

    event NeuronRegistration(uint16 indexed netuid, bytes32 hotkey, address indexed caller);

    function setUp() public {
        neuronMock = new MockNeuron();
        vm.etch(NEURON_PRECOMPILE, address(neuronMock).code);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        vault = new TreasuryVault(1 days, proposers, executors, admin);
    }

    function test_RegisterNeuron_Success_NoBurn() public {
        uint256 sentAmount = 1 ether;
        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(0);

        vm.deal(user, 10 ether);
        vm.prank(user);

        vm.expectEmit(true, true, true, true);
        emit NeuronRegistration(1, bytes32("hotkey"), user);

        bool success = vault.registerNeuron{ value: sentAmount }(1, bytes32("hotkey"));

        assertTrue(success);
        assertEq(user.balance, 10 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_RegisterNeuron_Success_WithBurn() public {
        uint256 sentAmount = 1 ether;
        uint256 burnCost = 0.2 ether;
        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnCost);

        vm.deal(user, 10 ether);
        vm.prank(user);

        vault.registerNeuron{ value: sentAmount }(1, bytes32("hotkey"));

        assertEq(user.balance, 10 ether - burnCost);
        assertEq(address(vault).balance, 0);
    }

    function test_RegisterNeuron_Success_ExactAmount() public {
        uint256 burnCost = 0.5 ether;
        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnCost);

        vm.deal(user, 1 ether);
        vm.prank(user);

        vault.registerNeuron{ value: burnCost }(1, bytes32("hotkey"));

        assertEq(user.balance, 0.5 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_RegisterNeuron_Revert_PrecompileFail() public {
        MockNeuron(NEURON_PRECOMPILE).setShouldFail(true);

        vm.deal(user, 1 ether);
        vm.prank(user);

        vm.expectRevert(TreasuryVault.NeuronRegistrationFailed.selector);
        vault.registerNeuron{ value: 1 ether }(1, bytes32("hotkey"));
    }

    function test_RegisterNeuron_Revert_RefundFail() public {
        uint256 sentAmount = 1 ether;
        uint256 burnCost = 0.1 ether;
        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnCost);

        revertingReceiver = new RevertingReceiver();
        vm.deal(address(revertingReceiver), 2 ether);

        vm.expectRevert(TreasuryVault.RefundError.selector);
        revertingReceiver.callRegister{ value: sentAmount }(address(vault), 1, bytes32("hotkey"));
    }

    function test_RegisterNeuron_ZeroValue() public {
        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(0);

        vm.prank(user);
        vault.registerNeuron{ value: 0 }(1, bytes32("hotkey"));

        assertEq(address(vault).balance, 0);
    }

    function testFuzz_RegisterNeuron_Success(uint96 sentAmount, uint96 burnAmount, uint16 netuid, bytes32 hotkey)
        public
    {
        vm.assume(burnAmount <= sentAmount);

        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnAmount);

        uint256 initialUserBalance = uint256(sentAmount) + 1 ether;
        vm.deal(user, initialUserBalance);

        vm.prank(user);
        vault.registerNeuron{ value: sentAmount }(netuid, hotkey);

        assertEq(user.balance, initialUserBalance - burnAmount);
        assertEq(address(vault).balance, 0);
    }

    function test_RegisterNeuron_WithPreExistingVaultBalance() public {
        vm.deal(address(vault), 100 ether);
        uint256 sentAmount = 1 ether;
        uint256 burnAmount = 0.1 ether;

        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnAmount);

        vm.deal(user, 5 ether);
        vm.prank(user);
        vault.registerNeuron{ value: sentAmount }(1, bytes32("hotkey"));

        assertEq(user.balance, 5 ether - burnAmount);
        assertEq(address(vault).balance, 100 ether);
    }

    function test_RegisterNeuron_BurnExceedsMsgValue_UsesVaultFunds() public {
        vm.deal(address(vault), 10 ether);

        uint256 sentAmount = 1 ether;
        uint256 burnAmount = 2 ether;

        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnAmount);

        vm.deal(user, 5 ether);
        vm.prank(user);

        vault.registerNeuron{ value: sentAmount }(1, bytes32("hotkey"));

        assertEq(user.balance, 4 ether);
        assertEq(address(vault).balance, 10 ether + sentAmount - burnAmount);
    }

    function test_RegisterNeuron_Revert_BalanceIncrease_Panic() public {
        uint256 sentAmount = 1 ether;

        MockNeuron(NEURON_PRECOMPILE).setMintAmount(1 ether);

        vm.deal(user, 5 ether);
        vm.prank(user);

        vm.expectRevert(stdError.arithmeticError);
        vault.registerNeuron{ value: sentAmount }(1, bytes32("hotkey"));
    }

    function test_Timelock_AccessControl() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PROPOSER_ROLE(), proposer));
        assertTrue(vault.hasRole(vault.EXECUTOR_ROLE(), executor));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), user));
    }

    function testFuzz_RegisterNeuron_HighValues(uint16 netuid, bytes32 hotkey) public {
        uint256 sentAmount = 100_000 ether;
        uint256 burnAmount = 99_999 ether;

        MockNeuron(NEURON_PRECOMPILE).setBurnAmount(burnAmount);

        vm.deal(user, sentAmount);
        vm.prank(user);
        vault.registerNeuron{ value: sentAmount }(netuid, hotkey);

        assertEq(user.balance, sentAmount - burnAmount);
    }
}
