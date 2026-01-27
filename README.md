# Bittensor Treasury Controller & Vault

A specialized governance system designed for the Bittensor network. This project provides a robust framework for
managing treasury funds, automating subnet operations, and enabling stake-based decentralized decision-making.

## 🏗 Architecture Overview

The system consists of two primary smart contracts:

### 1. TreasuryController (`src/controller/`)

A custom **Governor** implementation based on OpenZeppelin, optimized for Bittensor:

- **Stake-Based Voting**: Instead of standard ERC20 tokens, it leverages real-time stake and delegation data from the
  Bittensor network via the `IBittensorVotes` interface.
- **Subnet-Scoped**: Governance is targeted at a specific `netuid`, ensuring that only stakeholders relevant to that
  subnet have voting power.
- **Adjustable Quorum**: A configurable quorum numerator allows for flexible governance thresholds.
- **Atomic Operations**: Includes `proposeAndVote` functionality, allowing users to create a proposal and cast a vote in
  a single transaction (or automatically vote on an existing one).

### 2. TreasuryVault (`src/vault/`)

A sophisticated **TimelockController** that acts as the "brain" and "safe" of the system:

- **Foundry-Compatible Timelock**: Inherits proven security from OpenZeppelin's `TimelockController`.
- **Neuron Registration**: Directly integrates with the `NEURON_PRECOMPILE` (0x804) on the Bittensor EVM layer. This
  allows the vault to autonomously register neurons/hotkeys on subnets using treasury funds.
- **Automated Refunds**: Handles surplus TAO during registration processes, ensuring funds are returned to the caller.

---

## 💎 Key Differences from "Standard" Vaults

While built on top of industry-standard OpenZeppelin contracts, this implementation introduces critical enhancements for
the Bittensor ecosystem:

| Feature          | Standard OpenZeppelin Vault | Bittensor Treasury                           |
|------------------|-----------------------------|----------------------------------------------|
| **Voting Power** | ERC20 / NFT Snapshot        | **Live Bittensor Stake/Delegation**          |
| **Asset Focus**  | Standard EVM Tokens         | **Native TAO & Subnet Alpha**                |
| **Network Ops**  | Pure Token Storage          | **Direct Subnet Registration (Precompiles)** |
| **Governance**   | General Purpose             | **Subnet-Specific (NetUID Scoped)**          |

---

## ⚡ End-to-End Usage Workflow

Below is a step-by-step guide to deploying and operating the governance system using the provided helper scripts.

### 1. Configuration & Deployment

Set up your environment variables (NetUID, Governor settings) and deploy the contracts to the network.

```bash
# Edit .deploy.sh file if you want to change some envs, then run:
sh deploy.sh
```

**CRITICAL**: After deployment finishes, look at the console output and export the contract addresses for the next
steps:

```bash
export VAULT=<Vault_Address_From_Logs>
export GOVERNOR=<Governor_Address_From_Logs>
export MOCK_VOTES=<MockVotes_Address_From_Logs>

```

### 2. Wallet Setup

Generate necessary coldkeys and hotkeys using the Bittensor CLI to interact with the network.

```bash
btcli wallet new-coldkey --wallet.name vaultcoldkey

```

Then copy this cold key ss58 address, convert it to public key and then use it in neuron registration

### 3. Neuron Registration

Register your hotkey to a specific NetUID to become a validator/neuron on the network.

```bash
python3 tools/register_neuron.py --netuid 285 --hotkey <HOTKEY_ADDRESS> --rpc-url $RPC_URL --private-key $PRIVATE_KEY $VAULT

```

### 4. Set Weights (Subnet Ops)

Set weights on the subnet to establish the neuron's position and influence.

```bash
python3 tools/set_weights.py --network test --netuid 285 --weights 1 --uids <YOUR_UID> --wallet-name <WALLET_NAME> --hotkey-name <HOTKEY_NAME>

```

### 5. Assign Voting Power (Testnet/Mock Only)

Assign mock voting power (stake) to your wallet to enable voting capabilities during testing.

```bash
python3 tools/set_voting_power.py $MOCK_VOTES --hotkey $MY_WALLET_ADDRESS --amount 50000 --netuid 1 --rpc-url $RPC_URL

```

```bash
python3 tools/set_total_voting_power.py $MOCK_VOTES --hotkey $MY_WALLET_ADDRESS --amount 500000 --netuid 1 --rpc-url $RPC_URL

```

### 6. Create a Proposal

Submit a new proposal to the Governor (e.g., to transfer funds or execute a function).

```bash
export STAKING_PRECOMPILE=0x0000000000000000000000000000000000000805 # address of the precompile
export NEURON_HOT_KEY= # export neuron hot key you can get this using `btcli subnet show --netuid <netuid> --network <network> --verbose` and getting given neuron hot key and transforming it into bytes32 (public key)
python3 tools/propose_alfa_transfer.py $GOVERNOR $STAKING_PRECOMPILE --hotkey $NEURON_HOT_KEY --netuid <netuid> --amount <amount> --recipient $RECIPIENT_ADDRESS --description "Transfer v1" --rpc-url $RPC_URL

```

*Note the `Proposal ID` returned in the logs.*

### Check Proposal State

Monitor the status of the proposal to know when to queue or execute.

```bash
python3 tools/get_proposal_state.py $GOVERNOR --proposal-id $PID --rpc-url $RPC_URL

```

### 7. Cast Vote

Cast your vote (Support: 1 = For, 0 = Against) on the active proposal.

```bash
python3 tools/vote.py $GOVERNOR --proposal-id $PID --support 1 --rpc-url $RPC_URL

```

### 8. Queue Proposal

Once the voting period ends and the proposal succeeds, move it to the Timelock queue.

```bash
python3 tools/queue_alfa_proposal.py $GOVERNOR $STAKING_PRECOMPILE --hotkey $NEURON_HOT_KEY --netuid <netuid> --amount <amount> --recipient $RECIPIENT_ADDRESS --description "Transfer v1" --rpc-url $RPC_URL

```

### 9. Execute Proposal

After the timelock delay passes, execute the transaction to finalize the action on-chain.

```bash
python3 tools/execute_alfa_proposal.py $GOVERNOR $STAKING_PRECOMPILE --hotkey $NEURON_HOT_KEY --netuid <netuid> --amount <amount> --recipient $RECIPIENT_ADDRESS --description "Transfer v1" --rpc-url $RPC_URL

```

### 10. Verify Balance

Confirm the execution results by checking the validator's stake.

```bash
btcli stake list --network test --ss58 <YOUR_WALLET_ADDRESS>
```

---

## 🛠 Documentation & Tooling

To simplify interaction with these complex contracts, a dedicated Python toolset is provided.

* 📖 **[Python Tooling & Automation Guide](https://www.google.com/search?q=tools/README.md)**: Detailed documentation for
  proposing, voting, and managing the vault using our automated scripts.

---

## 🚀 Development & Usage

### Prerequisites

* [Foundry](https://book.getfoundry.sh/)
* Python 3.9+

### Build & Test

```shell
# Compile contracts
forge build

# Run unit tests
forge test

```

### Deployment

Use the Foundry scripts located in `script/` (e.g., `forge script script/Deployment.s.sol`).

---

## 🛡 Security

This project uses OpenZeppelin's battle-tested governance and timelock patterns. However, users should always verify
contract addresses and parameters before committing significant capital.

