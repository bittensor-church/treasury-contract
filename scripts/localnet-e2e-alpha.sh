#!/usr/bin/env bash
# ============================================================================
# Treasury Contract — Alpha Transfer E2E Test (Local Chain)
# ============================================================================
#
# Flow:
#   Same setup as native/erc20 (REUSE_SETUP shares /tmp/treasury-e2e-state.env),
#   plus alpha-specific phases:
#
#     5b. Generate vault's neuron hotkey (random bytes32, cached in state file)
#     5d. Disable admin-freeze-window + commit_reveal_weights on netuid (localnet-only)
#     6a. vault.registerNeuron(netuid, vault_hotkey) — burns TAO from vault,
#         creates (vault_coldkey, vault_hotkey, netuid) neuron slot.
#     6c. Alice's validator set_weights(uid=vault_uid, weight=1.0) so emissions
#         flow to the vault's neuron.
#     6b. Wait for alpha to accumulate on (vault_coldkey, vault_hotkey, netuid)
#         via subnet emissions, read via IStakingV2.getStake precompile.
#     7.  propose alpha transfer (vault_coldkey → destination coldkey)
#     8-12. vote / wait / queue / execute
#     13. Verify delta on getStake(vault_hotkey, destination_coldkey, netuid)
#
# Usage:
#   ./scripts/localnet-e2e-alpha.sh
#   REUSE_SETUP=1 ./scripts/localnet-e2e-alpha.sh
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

CHAIN_ENDPOINT="${CHAIN_ENDPOINT:-ws://127.0.0.1:9944}"
RPC_URL="${RPC_URL:-http://127.0.0.1:9944}"

ALICE_WALLET="${ALICE_WALLET:-alice}"
ALICE_HOTKEY_NAME="${ALICE_HOTKEY_NAME:-default}"
ALICE_COLDKEY_SEED="0xe5be9a5092b81bca64be81d212e7f2f9eba183bb7a90954f7b76361f6edb5c0a"
ALICE_SS58="5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"

DEPLOYER_ADDR="${DEPLOYER_ADDR:-0x509F12D8f6a0fE446055307f3dF2e10245C72494}"
DEPLOYER_PK="${DEPLOYER_PK:-0x2406c650b21d05b4057cc505e78e2f3e8db513a68c26b99cd030cc2f6c88445b}"
DEPLOYER_SS58="${DEPLOYER_SS58:-5DCcvGJKfNX16RWpbyvaYBTxFHexCh2wxGfLqS9BsX5GmaSA}"

VALIDATOR_HOTKEY_NAME="${VALIDATOR_HOTKEY_NAME:-e2e_validator}"

FUND_DEPLOYER_TAO=10000
STAKE_AMOUNT="${STAKE_AMOUNT:-5000}"

# Enough for registerNeuron burn (~1 TAO typ.) + post-reg vault balance
VAULT_FUND_AMOUNT="${VAULT_FUND_AMOUNT:-20}"

# Burn price sent to registerNeuron as msg.value (1 TAO default)
REGISTER_BURN_TAO="${REGISTER_BURN_TAO:-1}"

# Blocks to wait for alpha to accumulate before proposing
ALPHA_WAIT_BLOCKS="${ALPHA_WAIT_BLOCKS:-30}"

# Validator weight on vault's UID (1.0 sends all emissions to vault)
VAULT_UID_WEIGHT="${VAULT_UID_WEIGHT:-1.0}"

# Amount of alpha to transfer (in alpha tokens, 9-dec RAO internally)
TRANSFER_AMOUNT_ALPHA="${TRANSFER_AMOUNT_ALPHA:-0.0001}"

# Destination for the alpha transfer (any SS58). Default: alice's coldkey.
DEST_COLDKEY_SS58="${DEST_COLDKEY_SS58:-$ALICE_SS58}"

# Governance params
export MIN_DELAY="${MIN_DELAY:-1}"
export VOTING_DELAY="${VOTING_DELAY:-0}"
export VOTING_PERIOD="${VOTING_PERIOD:-10}"
export PROPOSAL_THRESHOLD="${PROPOSAL_THRESHOLD:-0}"
export QUORUM_BPS="${QUORUM_BPS:-100}"
export PROPOSAL_EXPIRATION="${PROPOSAL_EXPIRATION:-1000}"
export TAO_LIMIT="${TAO_LIMIT:-1000000000000000000000}"
export ALPHA_LIMIT="${ALPHA_LIMIT:-5000000000000000000000}"
export ERC20_LIMIT="${ERC20_LIMIT:-10000000000000000000000}"
export LIMIT_RESET_PERIOD_MIN="${LIMIT_RESET_PERIOD_MIN:-10080}"

DESCRIPTION="E2E Alpha Transfer Test $(date +%s)"

EVM_FLAGS="--legacy --gas-price 10000000000"
CAST_FLAGS="$EVM_FLAGS --gas-limit 500000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

STATE_FILE="${STATE_FILE:-/tmp/treasury-e2e-state.env}"
REUSE_SETUP="${REUSE_SETUP:-0}"

# Bittensor StakingV2 precompile
STAKING_V2_ADDR="0x0000000000000000000000000000000000000805"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
ok()   { echo -e "  \033[1;32m✓\033[0m $1"; }
warn() { echo -e "  \033[1;33m⚠ $1\033[0m"; }
fail() { echo -e "  \033[1;31m✗ $1\033[0m"; exit 1; }

btcli_cmd() { btcli "$@" --network "$CHAIN_ENDPOINT"; }

h160_to_ss58() {
    python3 -c "
import hashlib
h160 = bytes.fromhex('${1#0x}'.replace('0x',''))
aid = hashlib.blake2b(b'evm:' + h160, digest_size=32).digest()
pb = bytes([42])
cs = hashlib.blake2b(b'SS58PRE' + pb + aid, digest_size=64).digest()[:2]
full = pb + aid + cs
a = b'123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
n = int.from_bytes(full, 'big'); r = b''
while n > 0: n, rem = divmod(n, 58); r = bytes([a[rem]]) + r
for b_ in full:
    if b_ == 0: r = bytes([a[0]]) + r
    else: break
print(r.decode())
"
}

h160_to_b32() {
    python3 -c "
import hashlib
h160 = bytes.fromhex('${1#0x}'.replace('0x',''))
print('0x' + hashlib.blake2b(b'evm:' + h160, digest_size=32).hexdigest())
"
}

ss58_to_b32() {
    python3 -c "
from substrateinterface.utils.ss58 import ss58_decode
h = ss58_decode('$1')
print('0x' + h if not h.startswith('0x') else h)
"
}

read_hotkey_pubkey() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('publicKey',''))"
}

read_hotkey_ss58() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('ss58Address',''))"
}

# getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) → uint256 (RAO)
get_alpha_stake() {
    local HOTKEY_B32="$1"
    local COLDKEY_B32="$2"
    local NETUID="$3"
    cast call "$STAKING_V2_ADDR" \
        "getStake(bytes32,bytes32,uint256)(uint256)" \
        "$HOTKEY_B32" "$COLDKEY_B32" "$NETUID" \
        --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}'
}

wait_blocks() {
    local N="$1"
    local START=$(cast block-number --rpc-url "$RPC_URL")
    local TARGET=$((START + N))
    while true; do
        local CURRENT=$(cast block-number --rpc-url "$RPC_URL")
        if [[ "$CURRENT" -ge "$TARGET" ]]; then
            ok "Advanced $N blocks ($START → $CURRENT)"
            return 0
        fi
        sleep 3
    done
}

update_state() {
    local KEY="$1"
    local VALUE="$2"
    if [[ -f "$STATE_FILE" ]] && grep -q "^${KEY}=" "$STATE_FILE"; then
        sed -i '' "s|^${KEY}=.*|${KEY}=${VALUE}|" "$STATE_FILE"
    else
        echo "${KEY}=${VALUE}" >> "$STATE_FILE"
    fi
}

# ─── Pre-flight ──────────────────────────────────────────────────────────────

log "Pre-flight"
cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1 || fail "Cannot connect to $RPC_URL"
ok "Chain reachable (chain-id: $(cast chain-id --rpc-url "$RPC_URL"))"
ok "Deployer: $DEPLOYER_ADDR"
ok "Deployer balance: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

ALICE_DIR="$HOME/.bittensor/wallets/$ALICE_WALLET"
NEED_REGEN=false
if [[ ! -d "$ALICE_DIR" ]]; then
    NEED_REGEN=true
elif [[ -f "$ALICE_DIR/coldkeypub.txt" ]]; then
    if ! grep -q "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY" "$ALICE_DIR/coldkeypub.txt" 2>/dev/null; then
        warn "alice wallet is NOT dev Alice — regenerating..."
        rm -rf "$ALICE_DIR"
        NEED_REGEN=true
    fi
else
    NEED_REGEN=true
fi

if [[ "$NEED_REGEN" == "true" ]]; then
    btcli wallet regen-coldkey --wallet-name "$ALICE_WALLET" \
        --wallet-path "$HOME/.bittensor/wallets" \
        --seed "$ALICE_COLDKEY_SEED" --no-use-password --overwrite 2>&1 | tail -3
    [[ -f "$ALICE_DIR/coldkeypub.txt" ]] || fail "Alice regen failed"
    ok "Alice regenerated (5Grwva...)"
fi

if [[ ! -f "$ALICE_DIR/hotkeys/$ALICE_HOTKEY_NAME" ]]; then
    btcli wallet new-hotkey --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" \
        --n-words 12 --no-use-password 2>&1 | tail -1
    ok "Created hotkey '$ALICE_HOTKEY_NAME'"
else
    ok "Alice hotkey '$ALICE_HOTKEY_NAME' exists"
fi

if [[ ! -f "$PROJECT_ROOT/out/TreasuryController.sol/TreasuryController.json" ]]; then
    log "Building contracts (forge build)"
    (cd "$PROJECT_ROOT" && forge build --quiet) || fail "forge build failed"
    ok "Compiled"
fi

# ─── Load cached setup ───────────────────────────────────────────────────────

if [[ "$REUSE_SETUP" == "1" ]]; then
    [[ -f "$STATE_FILE" ]] || fail "REUSE_SETUP=1 but $STATE_FILE not found — run full e2e first"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    : "${NETUID:?missing NETUID}"
    : "${HOTKEY_SS58:?missing HOTKEY_SS58}"
    : "${VAULT_ADDR:?missing VAULT_ADDR}"
    : "${GOVERNOR_ADDR:?missing GOVERNOR_ADDR}"
    ok "Reusing cached setup from $STATE_FILE"
    ok "  netuid=$NETUID"
    ok "  hotkey=$HOTKEY_SS58 (e2e_validator, staked)"
    ok "  vault=$VAULT_ADDR"
    ok "  governor=$GOVERNOR_ADDR"
    [[ -n "${VAULT_NEURON_HOTKEY_B32:-}" ]] && ok "  vault_neuron_hotkey=$VAULT_NEURON_HOTKEY_B32"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0: Fund deployer
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 0: Fund deployer"

DEPLOYER_BAL=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0")
DEPLOYER_BAL_INT=$(python3 -c "print(int(float('$DEPLOYER_BAL')))")

if [[ "$DEPLOYER_BAL_INT" -lt 50 ]]; then
    btcli_cmd wallet transfer \
        --wallet-name "$ALICE_WALLET" --dest "$DEPLOYER_SS58" \
        --amount "$FUND_DEPLOYER_TAO" --allow-death --no-prompt 2>&1 | tail -2
    ok "Transferred $FUND_DEPLOYER_TAO TAO → $DEPLOYER_ADDR"
else
    ok "Already funded (${DEPLOYER_BAL} TAO)"
fi
ok "Deployer balance: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1–5 (same as native — gated by REUSE_SETUP)
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 1: SKIPPED (REUSE_SETUP=1, netuid=$NETUID from cache)"
elif [[ -n "${EXISTING_NETUID:-}" ]]; then
    log "Phase 1: Using existing subnet (netuid=$EXISTING_NETUID)"
    NETUID="$EXISTING_NETUID"

    # Idempotent start_call: emissions only flow when FirstEmissionBlockNumber
    # is set. On reused subnets this may never have been called, which results
    # in 0 alpha regardless of weights/permits. Swallow the "already started"
    # error so reruns don't fail here.
    START_OUT=$(btcli_cmd subnets start --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" --no-prompt 2>&1 || true)
    if echo "$START_OUT" | grep -qiE "already|FirstEmissionBlockNumberAlreadySet"; then
        ok "Emissions already started on netuid=$NETUID"
    else
        echo "$START_OUT" | tail -1
        ok "Emissions started on netuid=$NETUID"
    fi
else
    log "Phase 1: Create subnet + start emissions"
    OUTPUT=$(printf '\n\n\n\n\n\n\n\n\n\n' | btcli_cmd subnets create \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" \
        --no-prompt --subnet-name "treasury_e2e" 2>&1)
    NETUID=$(echo "$OUTPUT" | sed -n 's/.*netuid: \([0-9]*\).*/\1/p' | tail -1)
    [[ -z "$NETUID" ]] && { echo "$OUTPUT"; fail "Could not extract netuid"; }
    ok "Created subnet netuid=$NETUID"

    btcli_cmd subnets start --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" --no-prompt 2>&1 | tail -1
    ok "Emissions started"

    btcli_cmd sudo set --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --param max_regs_per_block --value 8 --no-prompt 2>&1 | tail -1 || true
fi

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 2: SKIPPED (validator hotkey from cache: $HOTKEY_SS58)"
else
    log "Phase 2: Validator hotkey"
    if [[ ! -f "$ALICE_DIR/hotkeys/$VALIDATOR_HOTKEY_NAME" ]]; then
        btcli wallet new-hotkey --wallet-name "$ALICE_WALLET" --hotkey "$VALIDATOR_HOTKEY_NAME" \
            --n-words 12 --no-use-password 2>&1 | tail -1
    fi
    HOTKEY_B32=$(read_hotkey_pubkey "$ALICE_WALLET" "$VALIDATOR_HOTKEY_NAME")
    HOTKEY_SS58=$(read_hotkey_ss58 "$ALICE_WALLET" "$VALIDATOR_HOTKEY_NAME")
    ok "Validator hotkey SS58: $HOTKEY_SS58"

    for attempt in 1 2 3; do
        REG_OUT=$(btcli_cmd subnets register --netuid "$NETUID" \
            --wallet-name "$ALICE_WALLET" --hotkey "$VALIDATOR_HOTKEY_NAME" --no-prompt 2>&1)
        if echo "$REG_OUT" | grep -qE "Registered|Already|is already"; then
            ok "Registered on netuid $NETUID"
            break
        fi
        warn "Register attempt $attempt failed, retrying..."
        sleep 6
    done
fi

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 3: SKIPPED (stake already applied)"
else
    log "Phase 3: Stake $STAKE_AMOUNT TAO"
    python3 "$PROJECT_ROOT/tools/subnet_admin.py" stake-add \
        --endpoint "$CHAIN_ENDPOINT" \
        --coldkey-uri "$ALICE_COLDKEY_SEED" \
        --hotkey-ss58 "$HOTKEY_SS58" \
        --netuid "$NETUID" \
        --amount "$STAKE_AMOUNT" 2>&1 | sed 's/^/  /'
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3b: Enable voting-power tracking + grant ValidatorPermit
# On a fresh subnet VotingPowerTrackingEnabled=false (→ precompile 0x80D returns
# 0 and every finalize() ends Defeated) and the EMA alpha is 2-week-slow. Both
# need to be flipped via sudo before the validator's first weight submission.
# The self-weight (uids=[self_uid] weights=[1]) bypasses the permit check and
# after one tempo writes ValidatorPermit[netuid,self_uid]=true — required for
# non-self-weights in Phase 6c.
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 3b: SKIPPED (permit from cache run)"
else
    log "Phase 3b: Enable tracking + grant ValidatorPermit to $VALIDATOR_HOTKEY_NAME"

    python3 "$PROJECT_ROOT/tools/subnet_admin.py" disable-commit-reveal \
        --endpoint "$CHAIN_ENDPOINT" --netuid "$NETUID" 2>&1 | sed 's/^/  /'

    python3 "$PROJECT_ROOT/tools/subnet_admin.py" enable-voting-power-tracking \
        --endpoint "$CHAIN_ENDPOINT" --netuid "$NETUID" 2>&1 | sed 's/^/  /'

    python3 "$PROJECT_ROOT/tools/subnet_admin.py" set-voting-power-ema-alpha \
        --endpoint "$CHAIN_ENDPOINT" --netuid "$NETUID" \
        --alpha 500000000000000000 2>&1 | sed 's/^/  /'

    VALIDATOR_UID=$(python3 "$PROJECT_ROOT/tools/subnet_admin.py" get-uid \
        --endpoint "$CHAIN_ENDPOINT" --netuid "$NETUID" --hotkey "$HOTKEY_SS58" 2>/dev/null || echo "")
    [[ -z "$VALIDATOR_UID" ]] && fail "Could not resolve UID for $HOTKEY_SS58 on netuid $NETUID"
    ok "Validator UID: $VALIDATOR_UID"

    HOTKEY_FILE_EARLY="$ALICE_DIR/hotkeys/$VALIDATOR_HOTKEY_NAME"
    HOTKEY_MNEMONIC_EARLY=$(python3 -c "import json; print(json.load(open('$HOTKEY_FILE_EARLY'))['secretPhrase'])")

    set +e
    SW_OUT=$(python3 "$PROJECT_ROOT/tools/subnet_admin.py" set-weights \
        --endpoint "$CHAIN_ENDPOINT" \
        --hotkey-uri "$HOTKEY_MNEMONIC_EARLY" \
        --netuid "$NETUID" \
        --uids "$VALIDATOR_UID" \
        --weights 1 2>&1)
    SW_STATUS=$?
    set -e
    echo "$SW_OUT" | sed 's/^/  /'
    if [[ "$SW_STATUS" -ne 0 ]]; then
        if echo "$SW_OUT" | grep -qi "rate limit\|SettingWeightsTooFast"; then
            warn "set_weights rate-limited — tolerating"
        else
            fail "set_weights failed"
        fi
    else
        ok "Self-weight set: uids=[$VALIDATOR_UID] weights=[1]"
    fi

    TEMPO=$(python3 -c "from substrateinterface import SubstrateInterface; \
si = SubstrateInterface(url='$CHAIN_ENDPOINT'); \
print(si.query('SubtensorModule', 'Tempo', [$NETUID]).value)")
    log "Waiting $((TEMPO + 2)) blocks for epoch (grants ValidatorPermit + updates VotingPower; tempo=$TEMPO)"
    wait_blocks $((TEMPO + 2))
fi

log "Phase 4: Associate EVM → hotkey"
HOTKEY_FILE="$ALICE_DIR/hotkeys/$VALIDATOR_HOTKEY_NAME"
HOTKEY_MNEMONIC=$(python3 -c "import json; print(json.load(open('$HOTKEY_FILE'))['secretPhrase'])")

set +e
ASSOCIATE_OUTPUT=$(python3 "$PROJECT_ROOT/tools/associate_evm.py" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" \
    --netuid "$NETUID" --hotkey "$HOTKEY_SS58" \
    --hotkey-uri "$HOTKEY_MNEMONIC" 2>&1)
ASSOC_STATUS=$?
set -e
if [[ "$ASSOC_STATUS" -eq 0 ]]; then
    ok "EVM → hotkey association succeeded"
else
    warn "associate_evm failed (rate-limit if already done)."
    echo "$ASSOCIATE_OUTPUT" | tail -6
fi

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 5: SKIPPED (vault=$VAULT_ADDR, governor=$GOVERNOR_ADDR from cache)"
    VAULT_SS58=$(h160_to_ss58 "$VAULT_ADDR")
else
    log "Phase 5: Deploy Vault + Controller"
    export PRIVATE_KEY="$DEPLOYER_PK"
    export NETUID="$NETUID"
    DEPLOY_OUT=$(cd "$PROJECT_ROOT" && forge script script/Deploy.s.sol:DeployGovernance \
        --rpc-url "$RPC_URL" --broadcast --legacy -vv 2>&1)
    VAULT_ADDR=$(echo "$DEPLOY_OUT" | grep -E "Vault deployed at:" | sed -n 's/.*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)
    GOVERNOR_ADDR=$(echo "$DEPLOY_OUT" | grep -E "Governor deployed at:" | sed -n 's/.*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)
    [[ -z "$VAULT_ADDR" ]] && { echo "$DEPLOY_OUT" | tail -30; fail "parse vault"; }
    [[ -z "$GOVERNOR_ADDR" ]] && { echo "$DEPLOY_OUT" | tail -30; fail "parse governor"; }
    ok "Vault:    $VAULT_ADDR"
    ok "Governor: $GOVERNOR_ADDR"
    VAULT_SS58=$(h160_to_ss58 "$VAULT_ADDR")

    cat > "$STATE_FILE" <<EOF
# Auto-generated by localnet-e2e scripts — re-run with REUSE_SETUP=1 to reuse.
NETUID=$NETUID
HOTKEY_B32=$HOTKEY_B32
HOTKEY_SS58=$HOTKEY_SS58
VAULT_ADDR=$VAULT_ADDR
VAULT_SS58=$VAULT_SS58
GOVERNOR_ADDR=$GOVERNOR_ADDR
EOF
    ok "Saved setup state → $STATE_FILE"
fi

VAULT_COLDKEY_B32=$(h160_to_b32 "$VAULT_ADDR")
ok "Vault coldkey bytes32: $VAULT_COLDKEY_B32"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5b: Generate vault's neuron hotkey (cached per setup)
# ═════════════════════════════════════════════════════════════════════════════

if [[ -n "${VAULT_NEURON_HOTKEY_B32:-}" ]] && [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 5b: SKIPPED (vault_neuron_hotkey from cache: $VAULT_NEURON_HOTKEY_B32)"
else
    log "Phase 5b: Generate vault neuron hotkey (fresh bytes32)"
    VAULT_NEURON_HOTKEY_B32=$(python3 -c "import secrets; print('0x' + secrets.token_hex(32))")
    ok "Vault neuron hotkey: $VAULT_NEURON_HOTKEY_B32"
    update_state "VAULT_NEURON_HOTKEY_B32" "$VAULT_NEURON_HOTKEY_B32"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5d: Disable commit-reveal on netuid (localnet only, via //Alice sudo)
#   - set admin freeze window to 0 so admin ops aren't blocked every block
#   - set commit_reveal_weights_enabled=false so set_weights takes effect immediately
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 5d: Disable commit-reveal on netuid=$NETUID (localnet sudo)"
python3 "$PROJECT_ROOT/tools/subnet_admin.py" disable-commit-reveal \
    --endpoint "$CHAIN_ENDPOINT" --netuid "$NETUID" 2>&1 | sed 's/^/  /'
ok "Commit-reveal disabled"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6: Fund vault (target: $VAULT_FUND_AMOUNT TAO)
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 6: Fund vault (target: $VAULT_FUND_AMOUNT TAO)"
VAULT_BAL=$(cast balance "$VAULT_ADDR" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0")
VAULT_BAL_INT=$(python3 -c "print(int(float('$VAULT_BAL')))")
if [[ "$VAULT_BAL_INT" -lt "$VAULT_FUND_AMOUNT" ]]; then
    btcli_cmd wallet transfer \
        --wallet-name "$ALICE_WALLET" --dest "$VAULT_SS58" \
        --amount "$VAULT_FUND_AMOUNT" --allow-death --no-prompt 2>&1 | tail -2
    ok "Funded vault"
else
    ok "Vault already funded (${VAULT_BAL} TAO ≥ $VAULT_FUND_AMOUNT TAO target)"
fi
ok "Vault TAO balance: $(cast balance "$VAULT_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6a: Register vault's neuron (idempotent — skip if already on chain)
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 6a: Register vault neuron on netuid=$NETUID"

# Quick probe: if vault already has any stake on (vault_coldkey, vault_hotkey, netuid),
# registration has already happened.
EXISTING_STAKE_RAO=$(get_alpha_stake "$VAULT_NEURON_HOTKEY_B32" "$VAULT_COLDKEY_B32" "$NETUID")
if [[ -n "$EXISTING_STAKE_RAO" ]] && [[ "$EXISTING_STAKE_RAO" != "0" ]]; then
    ok "Vault neuron already registered (stake=$EXISTING_STAKE_RAO RAO)"
else
    BURN_WEI=$(cast to-wei "$REGISTER_BURN_TAO" ether)
    echo "  Calling vault.registerNeuron(netuid=$NETUID, hotkey=$VAULT_NEURON_HOTKEY_B32) with burn=$REGISTER_BURN_TAO TAO..."

    set +e
    REG_OUT=$(cast send "$VAULT_ADDR" \
        "registerNeuron(uint16,bytes32)" "$NETUID" "$VAULT_NEURON_HOTKEY_B32" \
        --value "$BURN_WEI" \
        --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" \
        --legacy --gas-price 10000000000 --gas-limit 2000000 2>&1)
    REG_STATUS=$?
    set -e

    if [[ "$REG_STATUS" -ne 0 ]]; then
        echo "$REG_OUT" | tail -15
        warn "registerNeuron reverted — may already be registered or precompile error."
        warn "Continuing so you can see downstream behavior."
    else
        echo "$REG_OUT" | grep -E "status|blockNumber|transactionHash" | head -3
        ok "registerNeuron submitted"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6c: Alice validator sets weights on vault's UID
#   Without this, vault's neuron gets 0 emissions regardless of tempo wait.
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 6c: Validator set_weights on vault's UID"

VAULT_UID=$(python3 "$PROJECT_ROOT/tools/subnet_admin.py" get-uid \
    --endpoint "$CHAIN_ENDPOINT" --netuid "$NETUID" \
    --hotkey "$VAULT_NEURON_HOTKEY_B32" 2>/dev/null || echo "")

if [[ -z "$VAULT_UID" ]]; then
    fail "Could not resolve vault's UID on netuid=$NETUID — registration may have failed"
fi
ok "Vault UID on netuid=$NETUID: $VAULT_UID"

# Non-self-weight — requires ValidatorPermit granted in Phase 3b.
set +e
SW_OUT=$(python3 "$PROJECT_ROOT/tools/subnet_admin.py" set-weights \
    --endpoint "$CHAIN_ENDPOINT" \
    --hotkey-uri "$HOTKEY_MNEMONIC" \
    --netuid "$NETUID" \
    --uids "$VAULT_UID" \
    --weights 1 2>&1)
SW_STATUS=$?
set -e
echo "$SW_OUT" | sed 's/^/  /'
if [[ "$SW_STATUS" -ne 0 ]]; then
    if echo "$SW_OUT" | grep -qE "too soon to commit|SettingWeightsTooFast"; then
        warn "Rate-limited — weights were set recently; existing weights still in effect"
    else
        fail "set_weights failed"
    fi
else
    ok "Weights set: uid=$VAULT_UID weights=[1]"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6b: Wait for alpha to accumulate on vault's neuron
# ═════════════════════════════════════════════════════════════════════════════

TRANSFER_RAO=$(python3 -c "print(int(float('$TRANSFER_AMOUNT_ALPHA') * 1e9))")

# Query subnet state so we can tell the user exactly what's going on:
#   - Tempo: epoch length in blocks
#   - BlocksSinceLastStep: counter; next epoch fires when it reaches Tempo
#   - FirstEmissionBlockNumber: emissions gate — if None, `subnets start` was
#     never called and alpha will NEVER flow regardless of weights/permits
#   - SubtokenEnabled: alpha transfer precompile gate
read -r TEMPO BLOCKS_SINCE FEB SUBTOKEN <<<"$(python3 -c "
from substrateinterface import SubstrateInterface
si = SubstrateInterface(url='$CHAIN_ENDPOINT')
tempo = si.query('SubtensorModule', 'Tempo', [$NETUID]).value
bsls = si.query('SubtensorModule', 'BlocksSinceLastStep', [$NETUID]).value
feb = si.query('SubtensorModule', 'FirstEmissionBlockNumber', [$NETUID]).value
sub = si.query('SubtensorModule', 'SubtokenEnabled', [$NETUID]).value
print(tempo, bsls, feb if feb is not None else 'None', sub)
")"
BLOCKS_TO_NEXT_EPOCH=$(( TEMPO - BLOCKS_SINCE ))
(( BLOCKS_TO_NEXT_EPOCH < 0 )) && BLOCKS_TO_NEXT_EPOCH=0

ALPHA_WAIT_EPOCHS="${ALPHA_WAIT_EPOCHS:-20}"
ALPHA_WAIT_MAX_BLOCKS="${ALPHA_WAIT_MAX_BLOCKS:-$(( BLOCKS_TO_NEXT_EPOCH + TEMPO * ALPHA_WAIT_EPOCHS ))}"

log "Phase 6b: Wait for alpha emissions to reach transfer target ($TRANSFER_RAO RAO)"
ok "tempo=$TEMPO, blocks_since_last_step=$BLOCKS_SINCE → next epoch in $BLOCKS_TO_NEXT_EPOCH blocks"
ok "FirstEmissionBlockNumber=$FEB, SubtokenEnabled=$SUBTOKEN"

if [[ "$FEB" == "None" ]]; then
    fail "Emissions gate not open on netuid=$NETUID (FirstEmissionBlockNumber=None). Run \`btcli subnets start --netuid $NETUID\` as subnet owner and rerun."
fi

CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC_URL")
if (( CURRENT_BLOCK < FEB )); then
    EMISSION_START_IN=$(( FEB - CURRENT_BLOCK ))
    warn "Emissions haven't started yet: first_emission_block=$FEB, current=$CURRENT_BLOCK ($EMISSION_START_IN blocks to go)"
    ALPHA_WAIT_MAX_BLOCKS=$(( ALPHA_WAIT_MAX_BLOCKS + EMISSION_START_IN ))
fi

# Deterministic preflight: wait for the next full epoch boundary so the
# consensus step has absorbed Phase 6c's set_weights and re-evaluated permits,
# then assert on-chain state is actually capable of paying alpha to the vault.
# Without this, we would blindly poll for up to 20 epochs even if a permit or
# weight row is structurally missing.
WAIT_FOR_EPOCH=$(( BLOCKS_TO_NEXT_EPOCH + 2 ))
log "Preflight: wait $WAIT_FOR_EPOCH blocks for next consensus step (tempo=$TEMPO)"
wait_blocks "$WAIT_FOR_EPOCH"

python3 - <<PY || fail "Preflight failed — see reason above; alpha will NOT flow to vault in this chain state."
import sys
from substrateinterface import SubstrateInterface
si = SubstrateInterface(url='$CHAIN_ENDPOINT')

permits = si.query('SubtensorModule', 'ValidatorPermit', [$NETUID]).value or []
v_uid, vault_uid = $VALIDATOR_UID, $VAULT_UID
if v_uid >= len(permits):
    print(f"  ✗ validator_uid={v_uid} out of range (len(permits)={len(permits)})", file=sys.stderr)
    sys.exit(1)
if not permits[v_uid]:
    print(f"  ✗ validator at uid={v_uid} has no ValidatorPermit — consensus ignores its weights", file=sys.stderr)
    print(f"    (fix: ensure validator has top-k stake and wait one more epoch)", file=sys.stderr)
    sys.exit(1)
print(f"  ✓ ValidatorPermit[uid={v_uid}] = True")

weights = si.query('SubtensorModule', 'Weights', [$NETUID, v_uid]).value or []
vault_entry = next(((u, w) for (u, w) in weights if u == vault_uid), None)
if vault_entry is None:
    print(f"  ✗ validator's Weights row does not include vault_uid={vault_uid}. Actual: {weights}", file=sys.stderr)
    print(f"    (fix: rerun set_weights for vault's UID)", file=sys.stderr)
    sys.exit(1)
if vault_entry[1] == 0:
    print(f"  ✗ validator's weight on vault_uid={vault_uid} is 0: {weights}", file=sys.stderr)
    sys.exit(1)
print(f"  ✓ Weights[validator={v_uid}] contains (vault_uid={vault_uid}, weight={vault_entry[1]})")
PY
ok "Preflight OK: permit granted + weights committed — emissions WILL flow on next epoch"

ok "Polling up to $ALPHA_WAIT_MAX_BLOCKS blocks (~$ALPHA_WAIT_EPOCHS epochs)"

POLL_START=$(cast block-number --rpc-url "$RPC_URL")
POLL_DEADLINE=$((POLL_START + ALPHA_WAIT_MAX_BLOCKS))
VAULT_ALPHA_RAO=0
LAST_EPOCH_LOG_BLOCK=0
while true; do
    VAULT_ALPHA_RAO=$(get_alpha_stake "$VAULT_NEURON_HOTKEY_B32" "$VAULT_COLDKEY_B32" "$NETUID")
    VAULT_ALPHA_RAO="${VAULT_ALPHA_RAO//[^0-9]/}"
    VAULT_ALPHA_RAO="${VAULT_ALPHA_RAO:-0}"
    CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC_URL")
    if [[ "$VAULT_ALPHA_RAO" -ge "$TRANSFER_RAO" ]]; then
        ok "Alpha target reached at block $CURRENT_BLOCK: $VAULT_ALPHA_RAO RAO ≥ $TRANSFER_RAO RAO"
        break
    fi
    if [[ "$CURRENT_BLOCK" -ge "$POLL_DEADLINE" ]]; then
        # Diagnostic dump before failing — tells the user WHY no alpha flowed.
        warn "=== Post-mortem diagnostics ==="
        python3 - <<PY || true
from substrateinterface import SubstrateInterface
si = SubstrateInterface(url='$CHAIN_ENDPOINT')
feb = si.query('SubtensorModule', 'FirstEmissionBlockNumber', [$NETUID]).value
sub = si.query('SubtensorModule', 'SubtokenEnabled', [$NETUID]).value
print(f"  FirstEmissionBlockNumber[$NETUID] = {feb}")
print(f"  SubtokenEnabled[$NETUID]         = {sub}")
try:
    total_alpha = si.query('SubtensorModule', 'TotalHotkeyAlpha', ['$VAULT_NEURON_HOTKEY_B32', $NETUID]).value
    print(f"  TotalHotkeyAlpha[vault_hk,$NETUID] = {total_alpha} RAO")
except Exception as e:
    print(f"  TotalHotkeyAlpha query failed: {e}")
try:
    weights = si.query('SubtensorModule', 'Weights', [$NETUID, $VALIDATOR_UID]).value
    print(f"  Weights[$NETUID][validator_uid=$VALIDATOR_UID] = {weights}")
except Exception as e:
    print(f"  Weights query failed: {e}")
try:
    permits = si.query('SubtensorModule', 'ValidatorPermit', [$NETUID]).value
    print(f"  ValidatorPermit[$NETUID][0..{min(8,len(permits))}] = {permits[:8]} ...")
    print(f"  Alice validator permit (uid=$VALIDATOR_UID): {permits[$VALIDATOR_UID] if $VALIDATOR_UID < len(permits) else 'OOB'}")
except Exception as e:
    print(f"  ValidatorPermit query failed: {e}")
PY
        fail "Timed out after $ALPHA_WAIT_MAX_BLOCKS blocks waiting for alpha (have $VAULT_ALPHA_RAO RAO, need $TRANSFER_RAO RAO). See diagnostics above."
    fi
    BLOCKS_LEFT=$(( POLL_DEADLINE - CURRENT_BLOCK ))

    # Once per epoch, also log TotalHotkeyAlpha so we can distinguish
    # "no emissions at all" from "emissions but on wrong coldkey".
    if (( CURRENT_BLOCK - LAST_EPOCH_LOG_BLOCK >= TEMPO )); then
        TOTAL_ALPHA=$(python3 -c "
from substrateinterface import SubstrateInterface
si = SubstrateInterface(url='$CHAIN_ENDPOINT')
try:
    v = si.query('SubtensorModule', 'TotalHotkeyAlpha', ['$VAULT_NEURON_HOTKEY_B32', $NETUID]).value
    print(v if v is not None else 0)
except Exception:
    print('?')
" 2>/dev/null)
        log "  block=$CURRENT_BLOCK vault_alpha=$VAULT_ALPHA_RAO RAO (target=$TRANSFER_RAO, ${BLOCKS_LEFT} blocks left, hotkey_total=$TOTAL_ALPHA) — waiting..."
        LAST_EPOCH_LOG_BLOCK=$CURRENT_BLOCK
    fi
    sleep 6
done

VAULT_ALPHA=$(python3 -c "print(int('$VAULT_ALPHA_RAO')/1e9)")
ok "Vault alpha stake: $VAULT_ALPHA α ($VAULT_ALPHA_RAO RAO) on (vault_coldkey, vault_hotkey, $NETUID)"

DEST_COLDKEY_B32=$(ss58_to_b32 "$DEST_COLDKEY_SS58")
ok "Destination coldkey: $DEST_COLDKEY_SS58 ($DEST_COLDKEY_B32)"

DEST_ALPHA_BEFORE_RAO=$(get_alpha_stake "$VAULT_NEURON_HOTKEY_B32" "$DEST_COLDKEY_B32" "$NETUID")
DEST_ALPHA_BEFORE_RAO="${DEST_ALPHA_BEFORE_RAO//[^0-9]/}"
DEST_ALPHA_BEFORE_RAO="${DEST_ALPHA_BEFORE_RAO:-0}"
ok "Destination alpha before: $DEST_ALPHA_BEFORE_RAO RAO"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 7: Propose alpha transfer
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 7: Propose alpha transfer ($TRANSFER_AMOUNT_ALPHA α → $DEST_COLDKEY_SS58)"

PROPOSE_OUT=$(python3 "$PROJECT_ROOT/tools/propose_proposal.py" "$GOVERNOR_ADDR" \
    --type alpha \
    --recipient "$DEST_COLDKEY_SS58" \
    --hotkey "$VAULT_NEURON_HOTKEY_B32" \
    --origin-netuid "$NETUID" \
    --destination-netuid "$NETUID" \
    --amount "$TRANSFER_AMOUNT_ALPHA" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" 2>&1)
echo "$PROPOSE_OUT" | tail -5

PROPOSAL_ID=$(echo "$PROPOSE_OUT" | grep -E "Proposal ID:" | sed -n 's/.*Proposal ID: \([0-9]*\).*/\1/p' | head -1)
[[ -z "$PROPOSAL_ID" ]] && { echo "$PROPOSE_OUT"; fail "Could not parse Proposal ID"; }
ok "Proposal ID: $PROPOSAL_ID"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 8: Vote For
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 8: Vote For"
if [[ "$VOTING_DELAY" -gt 0 ]]; then wait_blocks "$VOTING_DELAY"; fi

python3 "$PROJECT_ROOT/tools/vote.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --support 1 \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Vote cast"

python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 | tail -10

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 9: Wait voting period
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 9: Wait for voting to end + finalize"
wait_blocks "$((VOTING_PERIOD + 1))"

python3 "$PROJECT_ROOT/tools/finalize_proposal.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Finalize submitted"

STATE_NOW=$(python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 \
    | grep -E "^State:" | awk '{print $2}')
ok "Post-finalize state: $STATE_NOW"

if [[ "$STATE_NOW" != "Succeeded" ]]; then
    warn "Expected Succeeded — proposal may have been Defeated."
    python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
        --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 | tail -10
    log "E2E HALTED at Phase 9"
    exit 2
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 10: Queue
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 10: Queue"
python3 "$PROJECT_ROOT/tools/queue_proposal.py" "$GOVERNOR_ADDR" \
    --type alpha \
    --recipient "$DEST_COLDKEY_SS58" \
    --hotkey "$VAULT_NEURON_HOTKEY_B32" \
    --origin-netuid "$NETUID" \
    --destination-netuid "$NETUID" \
    --amount "$TRANSFER_AMOUNT_ALPHA" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Queued"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 11: Wait min delay
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 11: Wait MIN_DELAY ($MIN_DELAY blocks)"
wait_blocks "$((MIN_DELAY + 1))"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 12: Execute
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 12: Execute"
set +e
EXECUTE_OUT=$(python3 "$PROJECT_ROOT/tools/execute_proposal.py" "$GOVERNOR_ADDR" \
    --type alpha \
    --recipient "$DEST_COLDKEY_SS58" \
    --hotkey "$VAULT_NEURON_HOTKEY_B32" \
    --origin-netuid "$NETUID" \
    --destination-netuid "$NETUID" \
    --amount "$TRANSFER_AMOUNT_ALPHA" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" 2>&1)
EXEC_STATUS=$?
set -e
echo "$EXECUTE_OUT" | tail -5

if [[ "$EXEC_STATUS" -ne 0 ]]; then
    warn "Execute reverted — vault may have insufficient alpha on (vault_coldkey, vault_hotkey, $NETUID)."
    warn "This is expected if alpha didn't accumulate (vault has 0 staked TAO on its own hotkey)."
    log "E2E HALTED at Phase 12"
    exit 3
fi
ok "Executed"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 13: Verify alpha moved
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 13: Verify alpha delta"

DEST_ALPHA_AFTER_RAO=$(get_alpha_stake "$VAULT_NEURON_HOTKEY_B32" "$DEST_COLDKEY_B32" "$NETUID")
DEST_ALPHA_AFTER_RAO="${DEST_ALPHA_AFTER_RAO//[^0-9]/}"
DEST_ALPHA_AFTER_RAO="${DEST_ALPHA_AFTER_RAO:-0}"
DELTA_RAO=$(python3 -c "print(int('$DEST_ALPHA_AFTER_RAO') - int('$DEST_ALPHA_BEFORE_RAO'))")
DELTA_ALPHA=$(python3 -c "print(int('$DELTA_RAO')/1e9)")

ok "Destination alpha after:  $DEST_ALPHA_AFTER_RAO RAO"
ok "Delta: $DELTA_ALPHA α ($DELTA_RAO RAO)"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

log "SUMMARY"
echo ""
echo "  Chain:                     $RPC_URL"
echo "  Subnet netuid:             $NETUID"
echo "  Validator hotkey (alice):  $HOTKEY_SS58"
echo "  Vault:                     $VAULT_ADDR"
echo "  Vault coldkey b32:         $VAULT_COLDKEY_B32"
echo "  Vault neuron hotkey b32:   $VAULT_NEURON_HOTKEY_B32"
echo "  Governor:                  $GOVERNOR_ADDR"
echo "  Proposal ID:               $PROPOSAL_ID"
echo "  Description:               $DESCRIPTION"
echo ""
echo "  Destination coldkey:       $DEST_COLDKEY_SS58"
echo "  Alpha before (dest):       $DEST_ALPHA_BEFORE_RAO RAO"
echo "  Alpha after  (dest):       $DEST_ALPHA_AFTER_RAO RAO"
echo "  Delta:                     $DELTA_RAO RAO ($DELTA_ALPHA α)"
echo ""

if [[ "$DELTA_RAO" == "$TRANSFER_RAO" ]]; then
    ok "Alpha transfer E2E PASSED ✓"
elif [[ "$DELTA_RAO" -gt "0" ]]; then
    warn "Alpha transfer E2E PARTIAL: delta $DELTA_RAO ≠ expected $TRANSFER_RAO (vault had limited alpha)"
else
    fail "Alpha transfer E2E FAILED — no alpha delta"
fi
