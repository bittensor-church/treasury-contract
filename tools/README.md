# Python Tooling & Automation Guide

This directory contains a set of scripts used for managing the Treasury Vault, interacting with the Bittensor network, and handling governance processes.

## 🛠 Project Architecture

The tools are designed to be modular, sharing common logic via the `utils/` package.

### Core Utilities (`tools/utils/`)

- **`common.py`**: Standardized Web3 connection setup and argument parsing.
- **`contract_loader.py`**: Logic for loading contract ABIs from artifacts (with minimal fallbacks if artifacts are missing).
- **`tx_handler.py`**: A robust wrapper for estimating gas, signing, and executing transactions with automated receipt waiting and error decoding.
- **`gov_utils.py`**: Specialized builders for governance calldata (Native TAO, ALFA, and ERC20 transfers).

---

## 🏛 Governance Workflow

Governance follows a three-step process: **Propose -> Queue -> Execute**.

### 1. Propose
Submit a new proposal to the `TreasuryController`.
- `propose_tao_transfer.py`: For Native TAO transfers.
- `propose_alfa_transfer.py`: For ALFA stake transfers.
- `propose_erc20_transfer.py`: For standard ERC20 token transfers.

### 2. Queue
After a proposal succeeds (voting period ends), it must be queued in the Timelock.
- `queue_tao_proposal.py` / `queue_alfa_proposal.py` / `queue_erc20_proposal.py`

### 3. Execute
Once the Timelock delay passes, the proposal can be executed.
- `execute_tao_proposal.py` / `execute_alfa_proposal.py` / `execute_erc20_proposal.py`

---

## 🌐 Bittensor & Subnet Operations

These scripts interact directly with the Subtensor chain using the `bittensor` SDK.

- **`register_neuron.py`**: Registers a new hotkey on a subnet via the `TreasuryVault`. Automatically fetches current burn costs.
- **`set_weights.py`**: Sets validator weights for a specific subnet.
- **`get_balance.py`**: Fetches real stake breakdown for a coldkey directly from the chain.
---

## 🧪 Mock System (Testing)

For local development or testing governance logic without real stake:
- `set_voting_power.py`: Set mock voting power for a specific key.
- `set_total_voting_power.py`: Set total network voting power.
- `get_voting_power.py`: Query current mock power and share percentage.
- `vote.py`: Cast a vote on a proposal.
- `get_proposal_state.py`: Check the current status (Active, Defeated, Executed, etc.) of a proposal.

---

## 🚀 Getting Started

1. **Environment**: Ensure you have a virtual environment active.
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   ```
2. **Configuration**: Most scripts require a `PRIVATE_KEY` environment variable or the `--private-key` flag.
3. **RPC**: You must provide a valid EVM RPC endpoint via `--rpc-url`.

---

## 📝 Note for Python Developers
The current implementation relies heavily on `web3.py` and `bittensor` SDK. When refactoring, consider:
- Standardizing error handling across all CLI scripts.
- Strengthening the `load_contract` fallback logic.
- Improving the logging output in `tx_handler.py` for better CI/CD integration.
