// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/mocks/MockBittensorVotes.sol";

contract MockBittensorVotesV2Test is Test {
    MockBittensorVotes votes;

    uint16 subnet1 = 1;
    uint16 subnet2 = 2;

    bytes32 hotkey1 = bytes32(uint256(0x123));
    bytes32 hotkey2 = bytes32(uint256(0x456));

    function setUp() public {
        votes = new MockBittensorVotes();
    }

    function testInitialVotingPowerIsZero() public {
        assertEq(votes.getVotingPower(subnet1, hotkey1), 0);
        assertEq(votes.getVotingPower(subnet2, hotkey2), 0);
        assertFalse(votes.isVotingPowerTrackingEnabled(subnet1));
        assertFalse(votes.isVotingPowerTrackingEnabled(subnet2));
    }

    function testSetVotingPowerEnablesTracking() public {
        votes.setVotingPower(subnet1, hotkey1, 100);
        assertEq(votes.getVotingPower(subnet1, hotkey1), 100);
        assertTrue(votes.isVotingPowerTrackingEnabled(subnet1));

        votes.setVotingPower(subnet2, hotkey2, 50);
        assertEq(votes.getVotingPower(subnet2, hotkey2), 50);
        assertTrue(votes.isVotingPowerTrackingEnabled(subnet2));
    }

    function testUpdatingVotingPower() public {
        votes.setVotingPower(subnet1, hotkey1, 200);
        assertEq(votes.getVotingPower(subnet1, hotkey1), 200);

        votes.setVotingPower(subnet1, hotkey1, 150);
        assertEq(votes.getVotingPower(subnet1, hotkey1), 150);
    }

    function testOtherFunctionsReturnDefault() public {
        assertEq(votes.getVotingPowerDisableAtBlock(subnet1), 0);
        assertEq(votes.getVotingPowerEmaAlpha(subnet1), 0);
    }
}
