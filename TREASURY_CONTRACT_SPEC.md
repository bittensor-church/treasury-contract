# Bittensor Subnet Treasury System (BACT)

## Project Overview
The Bittensor Treasury system is a decentralized governance framework designed to allow subnets to autonomously **accumulate, manage, and spend Alpha/TAO tokens**. It ensures that treasury funds are managed transparently by the subnet validators, with voting power directly linked to their **EMA Stake**.

## Architecture: The Adapter Pattern
The system follows a modular "Adapter Pattern" to separate fund custody from governance logic. This maximizes security by using audited standards while allowing for Bittensor-specific customizations.

### 1. Treasury Vault (The "Safe")
* **Role:** Acts as the secure storage for all accumulated Alpha/TAO.
* **Base:** Built on the **OpenZeppelin TimelockController**.
* **Identity:** Registered as a **Miner/Neuron** via the `NEURON_PRECOMPILE`. This allows the contract to receive incentives directly from the subnet.
* **Security:** Enforces a mandatory time delay (e.g., 24h) between the approval of a spend motion and its actual execution.

### 2. Treasury Controller (The "Brain")
* **Role:** Manages the proposal lifecycle and voting logic.
* **Voting Mechanism:** Queries the **Bittensor Voting Power (EMA Stake)** via a custom `IVotes` interface.
* **Authorization:** Once a proposal reaches the required **Quorum (e.g., 51% of total stake)**, it triggers the Vault's execution queue.



---

## Core Features
- **Neuron Registration:** Supports `burnedRegister` to allow the Treasury to participate in the subnet as a miner.
- **Voluntary Donations:** Open for contributions from any SS58 or H160 address.
- **Stake-Weighted Governance:** Voting power is proportional to the validator's stake, ensuring those with the most "skin in the game" lead the decision-making.
- **Cross-Chain Addressing:** Handles interaction between EVM (H160) and Subtensor (SS58) for fund disbursements.

---

## Operational Flow
1.  **Propose:** A validator creates a proposal to send funds to a specific SS58 address.
2.  **Vote:** Validators cast votes; weights are calculated based on their EMA Stake at the time of the proposal.
3.  **Queue:** Upon reaching quorum, the proposal is moved to the Timelock Vault.
4.  **Execute:** After the timelock period expires, the funds are released to the destination address.
