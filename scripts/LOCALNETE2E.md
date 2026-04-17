# Treasury Contract — Local Chain End-to-End Tests

c
Automated end-to-end tests against a local Bittensor subtensor node.
Three independent flows cover the full governance lifecycle:

| Script | Proposal Type | Adds |
|---|---|---|
| `localnet-e2e-native.sh` | Native TAO transfer | — |
| `localnet-e2e-alpha.sh`  | Alpha stake transfer | `registerNeuron` via vault |
| `localnet-e2e-erc20.sh`  | ERC20 token transfer | Test ERC20 deployment |

Each script runs independently. They share common setup (subnet, validator, stake, EVM association, vault/controller deploy) — the divergence is in the proposal payload.

## Prerequisites

| Tool | Purpose |
|---|---|
| **Local subtensor** | Running at `ws://127.0.0.1:9944` (also HTTP on same port) |
| **btcli** | Bittensor CLI for wallet/subnet/staking operations |
| **forge / cast** | Foundry tools for EVM deploys + calls |
| **python3** | SS58/H160 conversion helpers |
| **Alice wallet** | Pre-funded dev account (`~1M TAO` on local chain) |
| **Funded EVM account** | Deployer/voter (auto-funded from Alice in Phase 0) |

Python deps (`requirements.txt` + tools):
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Start the Local Subtensor

Follow the [Bittensor local subtensor guide](https://docs.bittensor.com/subtensor-nodes/local-subtensor). Default endpoint is `ws://127.0.0.1:9944`.

The scripts assume the node is already running — they will NOT start it for you.

## Import Alice Wallet

Alice is the pre-funded dev account on Bittensor local chains (~1M TAO). The scripts auto-regenerate Alice from the dev seed if missing, but you can do it manually:

```bash
btcli wallet regen-coldkey --wallet-name alice \
    --mnemonic "bottom drive obey lake curtain smoke basket hold race lonely fit walk"
btcli wallet new-hotkey --wallet-name alice --hotkey default --n-words 12 --no-use-password
```

Verify:
```bash
btcli wallet balance --wallet-name alice --network ws://127.0.0.1:9944
# Should show ~1,000,000 TAO
```

## Running the E2E Scripts

### Native TAO transfer

```bash
chmod +x scripts/localnet-e2e-native.sh
./scripts/localnet-e2e-native.sh
```

### Alpha transfer (after native)

```bash
./scripts/localnet-e2e-alpha.sh
```

### ERC20 transfer (after native)

```bash
./scripts/localnet-e2e-erc20.sh
```

### Reuse existing subnet

Each run creates a fresh subnet by default (costs ~1000 TAO from Alice). Skip subnet creation by pointing to an existing one:

```bash
EXISTING_NETUID=2 ./scripts/localnet-e2e-native.sh
```

### Reuse full setup between iterations

Once a full run completes Phase 5 (deploy), state is written to
`/tmp/treasury-e2e-state.env` (netuid, hotkey SS58, vault, governor). Subsequent
runs skip Phases 1–5 entirely and only re-run the proposal/vote/queue/execute
flow — great for iterating on proposal scripts without paying the 1000 TAO
subnet-create cost each time:

```bash
REUSE_SETUP=1 ./scripts/localnet-e2e-native.sh
```

Phases 0 + 6 still run (they top-up deployer / vault only if balances are low,
so repeated runs are cheap).

Force full re-setup:
```bash
rm /tmp/treasury-e2e-state.env
./scripts/localnet-e2e-native.sh
```

### Custom deployer

Override the deployer address/private-key at the top of the script or via env:

```bash
DEPLOYER_ADDR="0x..." DEPLOYER_PK="0x..." ./scripts/localnet-e2e-native.sh
```

## Phases — what each script does

### Phase 0: Pre-flight + fund deployer

- Verifies RPC reachable
- Regenerates Alice from dev seed if missing
- Transfers 10,000 TAO from Alice → deployer EVM-mapped SS58 (if balance < 50 TAO)

### Phase 1: Create subnet

Uses `btcli subnets create` (cost: ~1000 TAO). Starts emissions, bumps `max_regs_per_block`. Skipped if `EXISTING_NETUID` is set.

### Phase 2: Create hotkey + register validator

Creates hotkey `e2e_validator` under Alice and registers it on the subnet. This is the neuron whose stake produces **real voting power** for the governance test.

### Phase 3: Stake TAO → voting power

Alice stakes 5000 TAO to the validator hotkey (ratio adjustable). Stake on the subnet produces live voting power readable via the `IBittensorVotes` precompile (`0x80D`).

### Phase 4: Associate EVM address with hotkey

Calls `tools/associate_evm.py` to bind the **voter EVM address** to the staked hotkey. Without this, `IUidLookup` returns no mapping and the voter has 0 voting power.

> **⚠ Known audit finding K-7** — `associate_evm.py` uses an older pallet ABI. If this phase fails, the voting flow downstream will also fail (voter will have 0 voting power). The script continues regardless so you can observe the downstream effect.

### Phase 5: Deploy Vault + Controller

Delegates to `deploy.sh` (which runs `forge script Deploy.s.sol`). Parses deployed addresses from Forge output.

Localnet deploy parameters (tight for fast iteration):
| Env | Value | Meaning |
|---|---|---|
| `MIN_DELAY` | `1` | Timelock delay (blocks) |
| `VOTING_DELAY` | `0` | Blocks between propose and vote-open |
| `VOTING_PERIOD` | `10` | Voting window (blocks) |
| `QUORUM_BPS` | `100` | 1% quorum |
| `PROPOSAL_EXPIRATION` | `1000` | Blocks after succeed before expiry |
| `TAO_LIMIT` | `1000 ether` | Max TAO transfer per period |
| `LIMIT_RESET_PERIOD_MIN` | `10080` | Spend window (minutes, default 1 week) |

### Phase 6: Fund vault

Transfers 10 TAO from Alice → vault's EVM-mapped SS58 address (for the treasury to have something to send).

### Phase 7: Propose

`tools/propose_proposal.py --type native --amount X --recipient Y --description "..."`. Script captures the returned `Proposal ID` and stores it for subsequent phases.

### Phase 8: Vote

`tools/vote.py --proposal-id $PID --support 1`.

> **⚠ Known audit finding K-4** — `_voteSucceeded` is identical to `_quorumReached`. A proposal passes when quorum is reached, regardless of Against majority. The test uses a single For vote that reaches quorum.

### Phase 9: Wait voting period

Polls `get_proposal_state.py` until the proposal state transitions out of `Active` (should become `Succeeded` after `VOTING_PERIOD` blocks).

### Phase 10: Queue

`tools/queue_proposal.py --type native --amount ... --recipient ... --description "..."`. Must pass the **same** parameters used at proposal time.

### Phase 11: Wait min delay

Sleeps `MIN_DELAY` blocks (timelock).

### Phase 12: Execute

`tools/execute_proposal.py --type native ...`.

> **⚠ Known audit finding K-3** — Timelock executors list contains `address(0)` (open executor). Anyone can call `execute`. The script uses the deployer but any EVM account would work.

### Phase 13: Verify recipient balance

Reads the recipient's native balance before and after execute, asserts the delta matches the proposed amount.

## Expected observations (pre-fix)

Running against the **current** (pre-fix) codebase, expect:

| Phase | Expected |
|---|---|
| 4 | **FAIL** — associate_evm (K-7) pallet ABI mismatch |
| 7 | Might fail if voter has 0 voting power and `proposalThreshold > 0` — default threshold is 0 so propose should succeed |
| 8 | Vote accepted but with `weight = 0` (no association) |
| 9 | State becomes `Succeeded` anyway (K-4: quorum check, 0 ≥ 0) OR `Defeated` (depends on quorum math) |
| 12 | If state reached `Queued`, execute succeeds via K-3 |
| 13 | Recipient gets the TAO if full flow made it through |

The script **does not gate on bug presence** — it runs the intended flow and logs failures so you can see which audit findings actually bite.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CHAIN_ENDPOINT` | `ws://127.0.0.1:9944` | Subtensor WebSocket |
| `RPC_URL` | `http://127.0.0.1:9944` | EVM JSON-RPC |
| `DEPLOYER_ADDR` | `0x509F12D8...` | EVM deployer (localnet only — random dev key) |
| `DEPLOYER_PK` | `0x2406c650...` | Deployer private key (localnet only — random dev key) |
| `ALICE_WALLET` | `alice` | btcli wallet name |
| `ALICE_HOTKEY_NAME` | `default` | Alice hotkey name |
| `EXISTING_NETUID` | (empty) | Skip subnet creation — use this netuid |
| `STAKE_AMOUNT` | `5000` | TAO staked to validator in Phase 3 |
| `VAULT_FUND_AMOUNT` | `10` | TAO sent to vault in Phase 6 |
| `TRANSFER_AMOUNT` | `1` | TAO proposed in native transfer |

## Troubleshooting

### `execution fatal: Module(ModuleError { index: 22, error: [13, 0, 0, 0] })`

Gas estimation failure on Bittensor EVM. Scripts work around this with legacy txs + explicit gas:
```
--legacy --gas-price 10000000000 --gas-limit 5000000
```

### `Alice wallet not found`

Scripts auto-regenerate from the dev seed. If this fails, do it manually (see "Import Alice Wallet" above).

### `proposal state stuck at Active`

Voting period hasn't elapsed. Each local block is ~6–12s (depends on your subtensor config). With `VOTING_PERIOD=10`, expect ~1–2 minutes.

### `forge create` outputs dry-run instead of deploying

Add `--broadcast`. Scripts already set this via `FORGE_FLAGS`.

### `associate_evm` fails with `BadOrigin` or `InvalidSignature`

Known audit finding K-7. The pallet's `do_associate_evm_key` signature format changed (commit `943c29ce`, 2025-09-12) and `tools/associate_evm.py` still sends the old format. Left as-is per audit scope.

### Proposal reverts in execute with `TimelockInvalidOperationState`

Check the `MIN_DELAY` has elapsed and the proposal is in `Queued` state. Run `get_proposal_state.py` between Queue and Execute to confirm.

## Reference: contract state at each stage

Use `get_proposal_state.py` any time:
```bash
python3 tools/get_proposal_state.py $GOVERNOR --proposal-id $PID --rpc-url $RPC_URL
```

Proposal states:
```
Pending   → before VOTING_DELAY blocks elapse
Active    → voting window open
Succeeded → vote ended, quorum met (see K-4 caveat)
Queued    → Succeeded + queue() called
Executed  → Queued + execute() called after MIN_DELAY
Defeated  → vote ended without meeting quorum
Expired   → Succeeded but queue() not called before expiration
Canceled  → explicitly cancelled
```
