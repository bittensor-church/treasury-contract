# Audit & Diff Review Guide

This document is intended for security reviewers and auditors to help them focus on the **custom logic** introduced in
this project, separate from the industry-standard, already-audited OpenZeppelin (OZ) base contracts.

## 🔍 Scope Overview

The project relies on OpenZeppelin's `Governor` and `TimelockController`. The primary areas for review are the *
*overridden functions** and **custom bittensor integrations**.

---

## 🏦 TreasuryVault.sol

*Inherits from OZ `TimelockController`*

| Function / Area      | Status         | Review Notes                                                                                                                                                       |
|:---------------------|:---------------|:-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Constructor**      | Standard       | Simply initializes the OZ `TimelockController`.                                                                                                                    |
| **`registerNeuron`** | **PRECOMPILE** | Straightforward interaction with `NEURON_PRECOMPILE` (0x804). Uses standard `burnedRegister` selector. Low risk of failure due to precompile-controlled execution. |
| **`_processRefund`** | **UTILITY**    | Simple logic to return overpaid TAO. Standard value transfer.                                                                                                      |
| **Constants**        | Custom         | `NEURON_PRECOMPILE` address definition.                                                                                                                            |

---

## 🏛 TreasuryController.sol

*Inherits from OZ `Governor`, `GovernorSettings`, `GovernorTimelockControl`*

### 1. Custom Integration (Bittensor Votes)

The most critical change is replacing ERC20 snapshots with live Bittensor stake data.

| Function        | Status     | Review Notes                                                                                |
|:----------------|:-----------|:--------------------------------------------------------------------------------------------|
| **`_getVotes`** | **CUSTOM** | Overridden to query `BITTENSOR_VOTES.getVotingPower`.                                       |
| **`quorum`**    | **CUSTOM** | Overridden to query `BITTENSOR_VOTES.getTotalVotingPower` multiplied by a custom numerator. |

### 2. Custom Voting Logic (Tallies)

We use a custom `ProposalTallies` struct instead of the standard `GovernorCountingSimple` to ensure compatibility with
bittensor-style voting.

| Function                       | Status     | Review Notes                                                                                                                |
|:-------------------------------|:-----------|:----------------------------------------------------------------------------------------------------------------------------|
| **`struct ProposalTallies`**   | **CUSTOM** | Tracks voters and individual support.                                                                                       |
| **`mapping _proposalTallies`** | **CUSTOM** | Storage layout for vote counting.                                                                                           |
| **`_countVote`**               | **CUSTOM** | **Critical**. Handles how votes are recorded and weights are summed. Note: Allows vote updates (overwriting previous vote). |
| **`_quorumReached`**           | **CUSTOM** | Logic for checking if the required stake has participated.                                                                  |
| **`_voteSucceeded`**           | **CUSTOM** | Determines proposal success (For > Against).                                                                                |

### 3. UX & Flow Enhancements (New)

Logic introduced to streamline the proposal and voting process in a single transaction.

| Function             | Status           | Review Notes                                                                                                                                                                                                                                                                                                                   |
|:---------------------|:-----------------|:-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`proposeAndVote`** | **NEW / CUSTOM** | **Critical**. Wrapper function that attempts to create a proposal and cast a vote atomically. <br>1. Checks if proposal exists via hash.<br>2. If **new**: calls `propose`. If `votingDelay == 0`, casts vote immediately.<br>3. If **exists**: checks state. If `Active`, casts/updates vote. If `Pending`/`Closed`, reverts. |

### 4. Utility Functions

| Function                   | Status   | Review Notes                                                                                                                               |
|:---------------------------|:---------|:-------------------------------------------------------------------------------------------------------------------------------------------|
| **Overridden Boilerplate** | Standard | Functions like `state`, `votingDelay`, `_executor`, etc., only call `super` to resolve inheritance conflicts and are **standard OZ code**. |

---

## ⚠️ Security Checklist for Reviewers

1. **Precompile Interaction**: Verify the `registerNeuron` call encoding and gas handling.
2. **Refund Logic**: Ensure `_processRefund` is reentrancy-safe (though it's a simple value transfer).
3. **Voting Power Mapping**: Confirm that `IBittensorVotes` addresses (hotkeys/coldkeys) are correctly handled in
   `_getVotes`.
4. **Counting Integrity**: Check `_countVote` for weight calculation accuracy.
5. **ProposeAndVote Flow**: Validate that `proposeAndVote` correctly handles state transitions (specifically preventing
   votes during `Pending` state if `votingDelay > 0`) and does not bypass any Governor restrictions.