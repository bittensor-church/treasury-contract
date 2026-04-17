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

## End-to-End Usage Workflow

Below is a step-by-step guide to deploying and operating the governance system using the provided helper scripts.

### 1. Configuration & Deployment

Set up your environment variables (NetUID, Governor settings) and deploy the contracts to the network.

```bash
# Edit deploy.sh if you want to change some envs, then run:
sh deploy.sh
```

**CRITICAL**: After deployment finishes, look at the console output and export the contract addresses for the next
steps:

```bash
export VAULT=<Vault_Address_From_Logs>
export GOVERNOR=<Governor_Address_From_Logs>
export MOCK_VOTES=<MockVotes_Address_From_Logs>   # only on testnet/localnet
```

### 2. Wallet Setup

Generate necessary coldkeys and hotkeys using the Bittensor CLI.

```bash
btcli wallet new-coldkey --wallet.name vaultcoldkey
btcli wallet new-hotkey --wallet.name vaultcoldkey --hotkey.name vaulthotkey
```

Then copy the coldkey SS58 address and the hotkey SS58 address for the next steps.

### 3. Neuron Registration

Register the hotkey on a subnet via the TreasuryVault contract. The vault pays the burn cost.

```bash
python3 tools/register_neuron.py $VAULT \
    --netuid 285 \
    --hotkey <HOTKEY_BYTES32_PUBLIC_KEY> \
    --network test \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

**Note:** The `--hotkey` must be a 32-byte hex public key. You can obtain it from the SS58 hotkey
using `substrateinterface`.

### 4. Associate EVM Address

Link the vault's EVM address to the Bittensor hotkey. This is a **critical step** that enables the
vault to receive emissions and participate in EVM-based governance.

```bash
python3 tools/associate_evm.py \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --coldkey <SS58_COLDKEY> \
    --hotkey <SS58_HOTKEY> \
    --coldkey-seed "$COLDKEY_SEED"
```

### 5. Set Weights (Subnet Ops)

Set weights on the subnet to establish the neuron's position and influence.

```bash
python3 tools/set_weights.py \
    --network test \
    --netuid 285 \
    --weights 1 \
    --uids <YOUR_UID> \
    --wallet-name <WALLET_NAME> \
    --hotkey-name <HOTKEY_NAME>
```

### 6. Assign Voting Power (Testnet/Mock Only)

Assign mock voting power (stake) to your wallet to enable voting capabilities during testing.

```bash
python3 tools/set_voting_power.py $MOCK_VOTES \
    --hotkey $MY_WALLET_ADDRESS \
    --amount 50000 \
    --netuid 1 \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY

python3 tools/set_total_voting_power.py $MOCK_VOTES \
    --amount 500000 \
    --netuid 1 \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 7. Create a Proposal

Submit a new proposal to the Governor. The unified `propose_proposal.py` script supports three
transfer types via the `--type` flag: `native`, `alpha`, or `erc20`.

**Alpha transfer example:**
```bash
export STAKING_PRECOMPILE=0x0000000000000000000000000000000000000805
python3 tools/propose_proposal.py $GOVERNOR \
    --type alpha \
    --hotkey $NEURON_HOT_KEY \
    --netuid <netuid> \
    --amount <amount> \
    --recipient $RECIPIENT_ADDRESS \
    --staking-contract $STAKING_PRECOMPILE \
    --description "Transfer v1" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

**Native TAO transfer example:**
```bash
python3 tools/propose_proposal.py $GOVERNOR \
    --type native \
    --amount <amount> \
    --recipient $RECIPIENT_ADDRESS \
    --description "Transfer v1" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

*Note the `Proposal ID` returned in the logs.*

Alternatively, use `propose_and_vote_proposal.py` (same arguments) to create a proposal and
automatically cast a For vote in a single transaction.

### Check Proposal State

Monitor the status of the proposal to know when to queue or execute.

```bash
python3 tools/get_proposal_state.py $GOVERNOR \
    --proposal-id $PID \
    --rpc-url $RPC_URL
```

### 8. Cast Vote

Cast a Yes vote on the active proposal. Only `support=1` (For) is accepted — Against/Abstain and `castVoteBySig` are disabled. A proposal succeeds when For-votes strictly exceed the quorum threshold (`QUORUM_BPS` of total network voting power).

```bash
python3 tools/vote.py $GOVERNOR \
    --proposal-id $PID \
    --support 1 \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 9. Queue Proposal

Once the voting period ends and the proposal succeeds, move it to the Timelock queue.
**You must pass the exact same parameters** (type, amount, recipient, description, etc.) that were
used when creating the proposal.

```bash
python3 tools/queue_proposal.py $GOVERNOR \
    --type alpha \
    --hotkey $NEURON_HOT_KEY \
    --netuid <netuid> \
    --amount <amount> \
    --recipient $RECIPIENT_ADDRESS \
    --staking-contract $STAKING_PRECOMPILE \
    --description "Transfer v1" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 10. Execute Proposal

After the timelock delay passes, execute the transaction to finalize the action on-chain.

```bash
python3 tools/execute_proposal.py $GOVERNOR \
    --type alpha \
    --hotkey $NEURON_HOT_KEY \
    --netuid <netuid> \
    --amount <amount> \
    --recipient $RECIPIENT_ADDRESS \
    --staking-contract $STAKING_PRECOMPILE \
    --description "Transfer v1" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 11. Verify Balance

Confirm the execution results by checking the validator's stake.

```bash
python3 tools/get_balance.py <YOUR_SS58_ADDRESS> --network test
# or
btcli stake list --network test --ss58 <YOUR_WALLET_ADDRESS>
```

---

## 🛠 Documentation & Tooling

To simplify interaction with these complex contracts, a dedicated Python toolset is provided.

* **[Python Tooling & Automation Guide](tools/README.md)** — detailed documentation for all scripts including
  proposing, voting, and managing the vault.
* **[Local Chain E2E Tests](scripts/LOCALNETE2E.md)** — automated end-to-end shell scripts that drive the full
  governance lifecycle (propose → vote → queue → execute) against a local Bittensor subtensor, for three proposal
  types: native TAO, alpha stake, and ERC20.

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

