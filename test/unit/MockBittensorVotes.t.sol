// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// FIX 1: Named imports instead of global imports
import { Test } from "forge-std/Test.sol";
import { MockBittensorVotes } from "../../src/mocks/MockBittensorVotes.sol";
// Note: adjusting path to ../../src if your test folder structure is test/unit/

contract MockBittensorVotesTest is Test {
    MockBittensorVotes public mockVotes;

    function setUp() public {
        mockVotes = new MockBittensorVotes();
    }

    // FIX 2: Added 'view' modifier because this test doesn't modify state
    function testInitialVotingPowerIsZero() public view {
        uint256 power = mockVotes.getVotingPower(1, bytes32(uint256(123)));
        assertEq(power, 0);
    }

    function testSetVotingPower() public {
        bytes32 hotkey = bytes32(uint256(1));
        mockVotes.setVotingPower(1, hotkey, 1000);
        assertEq(mockVotes.getVotingPower(1, hotkey), 1000);
    }

    // FIX 3: Added 'view' modifier
    function testOtherFunctionsReturnDefault() public view {
        assertTrue(mockVotes.isVotingPowerTrackingEnabled(1));
        assertEq(mockVotes.getVotingPowerDisableAtBlock(1), 0);
        assertEq(mockVotes.getVotingPowerEmaAlpha(1), 0);
    }
}