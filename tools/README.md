# Python Tooling & Automation Guide

This directory contains scripts for managing the Treasury Vault, interacting with the Bittensor network, and handling governance processes.

## Project Architecture

The tools are designed to be modular, sharing common logic via the `utils/` package.

### Core Utilities (`tools/utils/`)

- **`common.py`**: Standardized Web3 connection setup and argument parsing.
- **`contract_loader.py`**: Logic for loading contract ABIs from artifacts (with minimal fallbacks if artifacts are missing).
- **`tx_handler.py`**: A robust wrapper for estimating gas, signing, and executing transactions with automated receipt waiting and error decoding.
- **`gov_utils.py`**: Specialized builders for governance calldata (Native TAO, Alpha, and ERC20 transfers) and helpers for SS58/hotkey conversion.

---

## Getting Started

1. **Environment**: Ensure you have a virtual environment active.
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   ```
2. **Configuration**: Most scripts require a `PRIVATE_KEY` environment variable or the `--private-key` flag.
3. **RPC**: You must provide a valid EVM RPC endpoint via `--rpc-url`.
4. **Contracts**: Run `forge build` first so the ABI artifacts exist in `out/`.

---

## Bittensor & Subnet Operations

### Register Neuron — `register_neuron.py`

Registers a hotkey on a subnet via the `TreasuryVault` contract. The vault pays the burn cost. This is how the vault becomes a registered miner on the subnet and can receive emissions.

```bash
python3 tools/register_neuron.py $VAULT \
    --netuid 285 \
    --hotkey <HOTKEY_BYTES32> \
    --network test \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

**Note:** The `--hotkey` must be a 32-byte hex public key (with or without `0x` prefix).

### Associate EVM Address — `associate_evm.py`

Associates an EVM address with a Bittensor hotkey on-chain. This is a **critical step** that links the vault's EVM address to a hotkey, enabling the vault to receive emissions and participate in EVM-based governance.

```bash
python3 tools/associate_evm.py \
    --rpc-url http://localhost:9944 \
    --private-key <EVM_PRIVATE_KEY> \
    --coldkey <SS58_COLDKEY> \
    --hotkey <SS58_HOTKEY> \
    --coldkey-seed <COLDKEY_SEED_PHRASE>
```

The `--coldkey-seed` can also be set via the `COLDKEY_SEED` environment variable.

### Set Weights — `set_weights.py`

Sets validator weights for a specific subnet using the `bittensor` SDK.

```bash
python3 tools/set_weights.py \
    --netuid 285 \
    --uids 0,1,2 \
    --weights 1,1,1 \
    --wallet-name <WALLET_NAME> \
    --hotkey-name <HOTKEY_NAME> \
    --network test
```

Supports `--hotkeys` as an alternative to `--uids` (comma-separated SS58 addresses). Weights are normalized by default (disable with `--no-normalize`). Use `--dry-run` to preview without submitting.

### Get Balance — `get_balance.py`

Fetches real stake breakdown for a coldkey directly from the Subtensor chain.

```bash
python3 tools/get_balance.py <SS58_ADDRESS> --network test
```

### Query Voting Power (Precompile) — `query_voting_power_precompile.py`

Queries voting power for an EVM address by chaining precompile calls: EVM Address -> UID Lookup -> Hotkey -> Voting Power. Uses `cast` CLI under the hood.

```bash
python3 tools/query_voting_power_precompile.py \
    --rpc-url http://localhost:9944 \
    --evm-address 0x... \
    --netuid 2
```

### Subnet Admin (sudo / UID lookup) — `subnet_admin.py`

Local-chain helpers via `substrate-interface`. Two subcommands:

- `disable-commit-reveal` — sudo-sets `admin_freeze_window=0` and `commit_reveal_weights_enabled=false` on a netuid. Needed before the validator can call `set_weights` directly on a freshly-created local subnet. Requires a sudo-capable signer URI (defaults to `//Alice`).
- `get-uid` — resolves a hotkey SS58 to its UID on a given netuid by querying `SubtensorModule.Uids`.

```bash
python3 tools/subnet_admin.py disable-commit-reveal \
    --netuid 2 \
    --endpoint ws://127.0.0.1:9944

python3 tools/subnet_admin.py get-uid \
    --netuid 2 \
    --hotkey 5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY \
    --endpoint ws://127.0.0.1:9944
```

---

## Governance Workflow

Governance follows a three-step process: **Propose -> Queue -> Execute**.

All three governance scripts (`propose_proposal.py`, `queue_proposal.py`, `execute_proposal.py`) use a unified `--type` flag to specify the transfer type: `native`, `alpha`, or `erc20`.

### 1. Propose — `propose_proposal.py`

Submit a new proposal to the `TreasuryController`.

**Native TAO transfer:**
```bash
python3 tools/propose_proposal.py $GOVERNOR \
    --type native \
    --amount 10.0 \
    --recipient <EVM_ADDRESS> \
    --description "Transfer 10 TAO to recipient" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

**Alpha transfer:**
```bash
python3 tools/propose_proposal.py $GOVERNOR \
    --type alpha \
    --amount 100.0 \
    --recipient <SS58_ADDRESS> \
    --staking-contract $STAKING_PRECOMPILE \
    --netuid 285 \
    --hotkey <HOTKEY_HEX> \
    --description "Transfer 100 Alpha" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

**ERC20 transfer:**
```bash
python3 tools/propose_proposal.py $GOVERNOR \
    --type erc20 \
    --amount 500.0 \
    --recipient <EVM_ADDRESS> \
    --token <TOKEN_ADDRESS> \
    --description "Transfer 500 tokens" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

*Note the `Proposal ID` returned in the logs.*

### 1b. Propose & Vote — `propose_and_vote_proposal.py`

Creates a proposal and automatically casts a vote (For) in a single transaction. If the proposal already exists and is Active, it casts a vote on it instead. Same arguments as `propose_proposal.py`.

```bash
python3 tools/propose_and_vote_proposal.py $GOVERNOR \
    --type native \
    --amount 10.0 \
    --recipient <EVM_ADDRESS> \
    --description "Transfer 10 TAO" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 2. Cast Vote — `vote.py`

Cast a Yes vote on an active proposal. Only `support=1` (For) is accepted — Against and Abstain revert with `InvalidVoteSupport`, and `castVoteBySig`/`castVoteWithReasonAndParamsBySig` are disabled. A proposal succeeds when For-votes strictly exceed the quorum threshold (`QUORUM_BPS` of total network voting power at the proposal snapshot).

```bash
python3 tools/vote.py $GOVERNOR \
    --proposal-id <PROPOSAL_ID> \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 3. Check Proposal State — `get_proposal_state.py`

Monitor the status of a proposal. Shows state (Pending/Active/Canceled/Defeated/Succeeded/Queued/Expired/Executed) and voting deadline.

```bash
python3 tools/get_proposal_state.py $GOVERNOR \
    --proposal-id <PROPOSAL_ID> \
    --rpc-url $RPC_URL
```

**Note:** This is a read-only query and does not require `--private-key`.

### 4. Finalize — `finalize_proposal.py`

Once the voting period ends, call `finalize` to snapshot the outcome (For-votes vs quorum threshold) into storage. Permissionless — any address may call. Must run after the deadline and before `queue`; without it, `state()` returns `Defeated` and queue reverts. Idempotent — a second call reverts with `AlreadyFinalized`.

```bash
python3 tools/finalize_proposal.py $GOVERNOR \
    --proposal-id <PROPOSAL_ID> \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 5. Queue — `queue_proposal.py`

Once the proposal is finalized as passed, move it to the Timelock queue. **You must pass the exact same parameters** (type, amount, recipient, description, etc.) that were used to create the proposal.

```bash
python3 tools/queue_proposal.py $GOVERNOR \
    --type native \
    --amount 10.0 \
    --recipient <EVM_ADDRESS> \
    --description "Transfer 10 TAO to recipient" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### 6. Execute — `execute_proposal.py`

After the timelock delay passes, execute the transaction. **You must pass the exact same parameters** as the original proposal.

```bash
python3 tools/execute_proposal.py $GOVERNOR \
    --type native \
    --amount 10.0 \
    --recipient <EVM_ADDRESS> \
    --description "Transfer 10 TAO to recipient" \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

---

## Mock System (Testing Only)

For local development or testing governance logic without real stake:

### Set Voting Power — `set_voting_power.py`

Set mock voting power for a specific hotkey.

```bash
python3 tools/set_voting_power.py $MOCK_VOTES \
    --hotkey <HOTKEY_HEX> \
    --amount 50000 \
    --netuid 1 \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### Set Total Voting Power — `set_total_voting_power.py`

Set the total network voting power for quorum calculations.

```bash
python3 tools/set_total_voting_power.py $MOCK_VOTES \
    --amount 500000 \
    --netuid 1 \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY
```

### Get Voting Power — `get_voting_power.py`

Query current mock voting power and share percentage.

```bash
python3 tools/get_voting_power.py $MOCK_VOTES \
    --hotkey <HOTKEY_HEX> \
    --netuid 1 \
    --rpc-url $RPC_URL
```

---

## Script Reference

| Script | Purpose | Requires Private Key |
|--------|---------|---------------------|
| `register_neuron.py` | Register hotkey on subnet via vault | Yes |
| `associate_evm.py` | Link EVM address to Bittensor hotkey | Yes |
| `set_weights.py` | Set validator weights on subnet | Yes (via bittensor wallet) |
| `subnet_admin.py` | Sudo disable commit-reveal / get UID (localnet) | Yes (sudo URI, e.g. `//Alice`) |
| `get_balance.py` | Query stake breakdown for coldkey | No |
| `query_voting_power_precompile.py` | Query voting power via precompiles | No |
| `propose_proposal.py` | Create a governance proposal | Yes |
| `propose_and_vote_proposal.py` | Create proposal + vote atomically | Yes |
| `vote.py` | Cast vote on active proposal | Yes |
| `get_proposal_state.py` | Query proposal status & votes | No |
| `queue_proposal.py` | Queue succeeded proposal in timelock | Yes |
| `execute_proposal.py` | Execute queued proposal after delay | Yes |
| `set_voting_power.py` | Set mock voting power (testing) | Yes |
| `set_total_voting_power.py` | Set mock total voting power (testing) | Yes |
| `get_voting_power.py` | Query mock voting power (testing) | No |
