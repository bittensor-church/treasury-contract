#!/usr/bin/env bash
# ============================================================================
# Treasury Contract — Native TAO Transfer E2E Test (Local Chain)
# ============================================================================
#
# Prerequisites:
#   - Local subtensor running at ws://127.0.0.1:9944
#   - btcli with Alice wallet (hotkey "default")
#   - forge/cast installed
#   - python3 + requirements.txt
#
# Flow:
#   0. Pre-flight + fund deployer EVM (from Alice)
#   1. Create subnet + start emissions
#   2. Create hotkey + register as validator
#   3. Alice stakes TAO → real voting power
#   4. Associate EVM voter → staked hotkey
#   5. Deploy TreasuryVault + TreasuryController (forge script)
#   6. Fund vault with TAO
#   7. Propose native transfer
#   8. Vote (For)
#   9. Wait voting period + finalize → Succeeded
#   10. Queue
#   11. Wait minDelay
#   12. Execute
#   13. Verify recipient balance
#
# Usage:
#   chmod +x scripts/localnet-e2e-native.sh
#   ./scripts/localnet-e2e-native.sh              # full setup + proposal flow
#
#   # Reuse previous setup (subnet + hotkey + stake + EVM assoc + deploy):
#   REUSE_SETUP=1 ./scripts/localnet-e2e-native.sh
#     → loads /tmp/treasury-e2e-state.env and skips Phases 1–5.
#     → Phases 0 + 6 still run (top-up deployer / vault if needed).
#     → proposal/vote/queue/execute always re-run (cheap, repeatable).
#
#   # Reuse only existing subnet (still redeploy contracts, re-associate, etc.):
#   EXISTING_NETUID=2 ./scripts/localnet-e2e-native.sh
#
#   # Reset setup cache (force full run):
#   rm /tmp/treasury-e2e-state.env && ./scripts/localnet-e2e-native.sh
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

CHAIN_ENDPOINT="${CHAIN_ENDPOINT:-ws://127.0.0.1:9944}"
RPC_URL="${RPC_URL:-http://127.0.0.1:9944}"

ALICE_WALLET="${ALICE_WALLET:-alice}"
ALICE_HOTKEY_NAME="${ALICE_HOTKEY_NAME:-default}"
ALICE_COLDKEY_SEED="0xe5be9a5092b81bca64be81d212e7f2f9eba183bb7a90954f7b76361f6edb5c0a"

# Pre-generated deployer EVM account (shared across all E2E scripts)
DEPLOYER_ADDR="${DEPLOYER_ADDR:-0x509F12D8f6a0fE446055307f3dF2e10245C72494}"
DEPLOYER_PK="${DEPLOYER_PK:-0x2406c650b21d05b4057cc505e78e2f3e8db513a68c26b99cd030cc2f6c88445b}"
DEPLOYER_SS58="${DEPLOYER_SS58:-5DCcvGJKfNX16RWpbyvaYBTxFHexCh2wxGfLqS9BsX5GmaSA}"

# Validator hotkey under alice — provides voting power
VALIDATOR_HOTKEY_NAME="${VALIDATOR_HOTKEY_NAME:-e2e_validator}"

# Amounts
FUND_DEPLOYER_TAO=10000
STAKE_AMOUNT="${STAKE_AMOUNT:-5000}"
VAULT_FUND_AMOUNT="${VAULT_FUND_AMOUNT:-10}"
TRANSFER_AMOUNT="${TRANSFER_AMOUNT:-1}"

# Fresh recipient EVM address (no conflicting state)
RECIPIENT_ADDR="${RECIPIENT_ADDR:-0xd10375caed456c5902D7B155117Dd155398145C7}"

# Governance params (passed to deploy.sh as env vars)
export MIN_DELAY="${MIN_DELAY:-1}"
export VOTING_DELAY="${VOTING_DELAY:-0}"
export VOTING_PERIOD="${VOTING_PERIOD:-10}"
export PROPOSAL_THRESHOLD="${PROPOSAL_THRESHOLD:-0}"
export QUORUM_BPS="${QUORUM_BPS:-100}"
export PROPOSAL_EXPIRATION="${PROPOSAL_EXPIRATION:-1000}"
export TAO_LIMIT="${TAO_LIMIT:-1000000000000000000000}"       # 1000 TAO
export ALPHA_LIMIT="${ALPHA_LIMIT:-5000000000000000000000}"
export ERC20_LIMIT="${ERC20_LIMIT:-10000000000000000000000}"
export LIMIT_RESET_PERIOD_MIN="${LIMIT_RESET_PERIOD_MIN:-10080}"

# Proposal description — MUST be identical across propose/queue/execute
DESCRIPTION="E2E Native Transfer Test"

# Bittensor local chain requires legacy txs + explicit gas
EVM_FLAGS="--legacy --gas-price 10000000000"
FORGE_FLAGS="$EVM_FLAGS --gas-limit 5000000 --broadcast"
CAST_FLAGS="$EVM_FLAGS --gas-limit 500000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Persistent state between runs (REUSE_SETUP reads from here)
STATE_FILE="${STATE_FILE:-/tmp/treasury-e2e-state.env}"
REUSE_SETUP="${REUSE_SETUP:-0}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
ok()   { echo -e "  \033[1;32m✓\033[0m $1"; }
warn() { echo -e "  \033[1;33m⚠ $1\033[0m"; }
fail() { echo -e "  \033[1;31m✗ $1\033[0m"; exit 1; }

btcli_cmd() { btcli "$@" --network "$CHAIN_ENDPOINT"; }

# H160 → substrate account_id (bytes32 hex) via HashedAddressMapping
h160_to_substrate_b32() {
    python3 -c "
import hashlib
h160 = bytes.fromhex('${1#0x}')
print('0x' + hashlib.blake2b(b'evm:' + h160, digest_size=32).hexdigest())
"
}

# H160 → SS58 (prefix 42) via HashedAddressMapping
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

read_hotkey_pubkey() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('publicKey',''))"
}

read_hotkey_ss58() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('ss58Address',''))"
}

# Poll state() via get_proposal_state.py until it equals $2 (or timeout)
wait_for_state() {
    local GOVERNOR="$1"
    local TARGET_STATE="$2"
    local PID="$3"
    local MAX_WAIT="${4:-300}"
    local WAITED=0
    while true; do
        STATE=$(python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR" \
            --proposal-id "$PID" --rpc-url "$RPC_URL" 2>/dev/null \
            | grep -E "^State:" | awk '{print $2}' || echo "Unknown")
        if [[ "$STATE" == "$TARGET_STATE" ]]; then
            ok "State reached: $TARGET_STATE"
            return 0
        fi
        if [[ "$WAITED" -ge "$MAX_WAIT" ]]; then
            fail "Timeout waiting for state=$TARGET_STATE (current: $STATE after ${MAX_WAIT}s)"
        fi
        echo "  waiting for state=$TARGET_STATE (current: $STATE, elapsed ${WAITED}s)"
        sleep 6
        WAITED=$((WAITED + 6))
    done
}

# Wait N blocks by polling block_number
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

# ─── Pre-flight ──────────────────────────────────────────────────────────────

log "Pre-flight"
cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1 || fail "Cannot connect to $RPC_URL"
ok "Chain reachable (chain-id: $(cast chain-id --rpc-url "$RPC_URL"))"
ok "Deployer: $DEPLOYER_ADDR"
ok "Deployer balance: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

# Ensure Alice wallet (regen from dev seed if missing or mismatched)
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

# Ensure forge artifacts exist
if [[ ! -f "$PROJECT_ROOT/out/TreasuryController.sol/TreasuryController.json" ]]; then
    log "Building contracts (forge build)"
    (cd "$PROJECT_ROOT" && forge build --quiet) || fail "forge build failed"
    ok "Compiled"
fi

# ─── Load cached setup (if REUSE_SETUP=1) ────────────────────────────────────

if [[ "$REUSE_SETUP" == "1" ]]; then
    [[ -f "$STATE_FILE" ]] || fail "REUSE_SETUP=1 but $STATE_FILE not found — run full e2e first"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    : "${NETUID:?missing NETUID in $STATE_FILE}"
    : "${HOTKEY_SS58:?missing HOTKEY_SS58 in $STATE_FILE}"
    : "${VAULT_ADDR:?missing VAULT_ADDR in $STATE_FILE}"
    : "${GOVERNOR_ADDR:?missing GOVERNOR_ADDR in $STATE_FILE}"
    ok "Reusing cached setup from $STATE_FILE"
    ok "  netuid=$NETUID"
    ok "  hotkey=$HOTKEY_SS58"
    ok "  vault=$VAULT_ADDR"
    ok "  governor=$GOVERNOR_ADDR"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0: Fund deployer EVM account
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 0: Fund deployer"

DEPLOYER_BAL=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0")
DEPLOYER_BAL_INT=$(python3 -c "print(int(float('$DEPLOYER_BAL')))")

if [[ "$DEPLOYER_BAL_INT" -lt 50 ]]; then
    btcli_cmd wallet transfer \
        --wallet-name "$ALICE_WALLET" \
        --dest "$DEPLOYER_SS58" \
        --amount "$FUND_DEPLOYER_TAO" \
        --allow-death \
        --no-prompt 2>&1 | tail -2
    ok "Transferred $FUND_DEPLOYER_TAO TAO → $DEPLOYER_ADDR"
else
    ok "Already funded (${DEPLOYER_BAL} TAO)"
fi
ok "Deployer balance: $(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1: Create subnet + start emissions
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 1: SKIPPED (REUSE_SETUP=1, netuid=$NETUID from cache)"
elif [[ -n "${EXISTING_NETUID:-}" ]]; then
    log "Phase 1: Using existing subnet (netuid=$EXISTING_NETUID)"
    NETUID="$EXISTING_NETUID"
    ok "netuid $NETUID (existing)"
else
    log "Phase 1: Create subnet + start emissions"
    OUTPUT=$(printf '\n\n\n\n\n\n\n\n\n\n' | btcli_cmd subnets create \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" \
        --no-prompt --subnet-name "treasury_e2e" 2>&1)
    NETUID=$(echo "$OUTPUT" | sed -n 's/.*netuid: \([0-9]*\).*/\1/p' | tail -1)
    [[ -z "$NETUID" ]] && { echo "$OUTPUT"; fail "Could not extract netuid from create output"; }
    ok "Created subnet netuid=$NETUID"

    btcli_cmd subnets start --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" --no-prompt 2>&1 | tail -1
    ok "Emissions started"

    btcli_cmd sudo set --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --param max_regs_per_block --value 8 --no-prompt 2>&1 | tail -1 || true
    ok "max_regs_per_block → 8"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: Create hotkey + register as validator
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 2: SKIPPED (validator hotkey from cache: $HOTKEY_SS58)"
else
    log "Phase 2: Validator hotkey"

    if [[ ! -f "$ALICE_DIR/hotkeys/$VALIDATOR_HOTKEY_NAME" ]]; then
        btcli wallet new-hotkey --wallet-name "$ALICE_WALLET" --hotkey "$VALIDATOR_HOTKEY_NAME" \
            --n-words 12 --no-use-password 2>&1 | tail -1
        ok "Created hotkey '$VALIDATOR_HOTKEY_NAME'"
    else
        ok "Hotkey '$VALIDATOR_HOTKEY_NAME' exists"
    fi

    HOTKEY_B32=$(read_hotkey_pubkey "$ALICE_WALLET" "$VALIDATOR_HOTKEY_NAME")
    HOTKEY_SS58=$(read_hotkey_ss58 "$ALICE_WALLET" "$VALIDATOR_HOTKEY_NAME")
    ok "Validator hotkey bytes32: $HOTKEY_B32"
    ok "Validator hotkey SS58:    $HOTKEY_SS58"

    # Register on subnet (retry if rate-limited)
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

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3: Stake TAO → real voting power
# Direct SubtensorModule.add_stake (bypasses btcli's MEV-shield aggregate path
# which is unreliable on fresh localnets).
# ═════════════════════════════════════════════════════════════════════════════

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
    ok "Staked $STAKE_AMOUNT TAO on $VALIDATOR_HOTKEY_NAME"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3b: Enable voting-power tracking + grant ValidatorPermit
# On a fresh subnet:
#   - VotingPowerTrackingEnabled defaults to false → precompile 0x80D returns 0
#     → every finalize() sees forVotes=0, threshold=0 → Defeated. Must enable.
#   - VotingPowerEmaAlpha defaults to 0.00357e18 (2-week e-folding) → localnet
#     never accumulates voting power in test time. Bump to 0.5e18 for fast tests.
#   - Validator hotkey needs to set_weights once and a tempo must pass so the
#     epoch writes ValidatorPermit[netuid,uid]=true. uids=[self_uid] is a
#     self-weight → bypasses the permit check on first submission.
# Direct substrate set_weights bypasses the bittensor SDK's commit-reveal path
# (which blocks on drand when CommitRevealWeightsEnabled was ever true).
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

    HOTKEY_FILE="$ALICE_DIR/hotkeys/$VALIDATOR_HOTKEY_NAME"
    HOTKEY_MNEMONIC=$(python3 -c "import json; print(json.load(open('$HOTKEY_FILE'))['secretPhrase'])")

    set +e
    SW_OUT=$(python3 "$PROJECT_ROOT/tools/subnet_admin.py" set-weights \
        --endpoint "$CHAIN_ENDPOINT" \
        --hotkey-uri "$HOTKEY_MNEMONIC" \
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
        ok "Weights set: uids=[$VALIDATOR_UID] weights=[1]"
    fi

    TEMPO=$(python3 -c "from substrateinterface import SubstrateInterface; \
si = SubstrateInterface(url='$CHAIN_ENDPOINT'); \
print(si.query('SubtensorModule', 'Tempo', [$NETUID]).value)")
    log "Waiting $((TEMPO + 2)) blocks for epoch (grants ValidatorPermit + updates VotingPower; tempo=$TEMPO)"
    wait_blocks $((TEMPO + 2))
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4: Associate deployer EVM address → staked hotkey
# (Always runs — pallet-side rate limit makes duplicate calls a no-op / warn.)
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 4: Associate EVM → hotkey (for real voting power)"

HOTKEY_FILE="$ALICE_DIR/hotkeys/$VALIDATOR_HOTKEY_NAME"
HOTKEY_MNEMONIC=$(python3 -c "import json; print(json.load(open('$HOTKEY_FILE'))['secretPhrase'])")

set +e
ASSOCIATE_OUTPUT=$(python3 "$PROJECT_ROOT/tools/associate_evm.py" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" \
    --netuid "$NETUID" \
    --hotkey "$HOTKEY_SS58" \
    --hotkey-uri "$HOTKEY_MNEMONIC" 2>&1)
ASSOC_STATUS=$?
set -e

if [[ "$ASSOC_STATUS" -eq 0 ]]; then
    ok "EVM → hotkey association succeeded"
else
    warn "associate_evm failed. Continuing — voter may have 0 voting power."
    echo "$ASSOCIATE_OUTPUT" | tail -10
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5: Deploy Vault + Controller
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 5: SKIPPED (vault=$VAULT_ADDR, governor=$GOVERNOR_ADDR from cache)"
    VAULT_SS58=$(h160_to_ss58 "$VAULT_ADDR")
else
    log "Phase 5: Deploy Vault + Controller"

    export PRIVATE_KEY="$DEPLOYER_PK"
    export NETUID="$NETUID"

    # Capture forge script output — parse deployed addresses from console.log
    DEPLOY_OUT=$(cd "$PROJECT_ROOT" && forge script script/Deploy.s.sol:DeployGovernance \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --legacy \
        -vv 2>&1)

    VAULT_ADDR=$(echo "$DEPLOY_OUT" | grep -E "Vault deployed at:" | sed -n 's/.*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)
    GOVERNOR_ADDR=$(echo "$DEPLOY_OUT" | grep -E "Governor deployed at:" | sed -n 's/.*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)

    [[ -z "$VAULT_ADDR" ]] && { echo "$DEPLOY_OUT" | tail -30; fail "Could not parse Vault address"; }
    [[ -z "$GOVERNOR_ADDR" ]] && { echo "$DEPLOY_OUT" | tail -30; fail "Could not parse Governor address"; }

    ok "Vault:    $VAULT_ADDR"
    ok "Governor: $GOVERNOR_ADDR"

    VAULT_SS58=$(h160_to_ss58 "$VAULT_ADDR")
    ok "Vault SS58: $VAULT_SS58"

    # Persist setup so subsequent runs can REUSE_SETUP=1
    cat > "$STATE_FILE" <<EOF
# Auto-generated by localnet-e2e-native.sh — re-run with REUSE_SETUP=1 to reuse.
NETUID=$NETUID
HOTKEY_B32=$HOTKEY_B32
HOTKEY_SS58=$HOTKEY_SS58
VAULT_ADDR=$VAULT_ADDR
VAULT_SS58=$VAULT_SS58
GOVERNOR_ADDR=$GOVERNOR_ADDR
EOF
    ok "Saved setup state → $STATE_FILE"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6: Fund vault
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 6: Fund vault (target: $VAULT_FUND_AMOUNT TAO)"

VAULT_BAL=$(cast balance "$VAULT_ADDR" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0")
VAULT_BAL_INT=$(python3 -c "print(int(float('$VAULT_BAL')))")

if [[ "$VAULT_BAL_INT" -lt "$VAULT_FUND_AMOUNT" ]]; then
    btcli_cmd wallet transfer \
        --wallet-name "$ALICE_WALLET" \
        --dest "$VAULT_SS58" \
        --amount "$VAULT_FUND_AMOUNT" \
        --allow-death \
        --no-prompt 2>&1 | tail -2
    ok "Funded vault"
else
    ok "Vault already funded (${VAULT_BAL} TAO ≥ $VAULT_FUND_AMOUNT TAO target)"
fi
ok "Vault balance: $(cast balance "$VAULT_ADDR" --rpc-url "$RPC_URL" --ether) TAO"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 7: Propose native transfer
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 7: Propose native transfer ($TRANSFER_AMOUNT TAO → $RECIPIENT_ADDR)"

RECIPIENT_BAL_BEFORE=$(cast balance "$RECIPIENT_ADDR" --rpc-url "$RPC_URL" --ether)
ok "Recipient balance before: $RECIPIENT_BAL_BEFORE TAO"

PROPOSE_OUT=$(python3 "$PROJECT_ROOT/tools/propose_proposal.py" "$GOVERNOR_ADDR" \
    --type native \
    --amount "$TRANSFER_AMOUNT" \
    --recipient "$RECIPIENT_ADDR" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" 2>&1)
echo "$PROPOSE_OUT" | tail -5

PROPOSAL_ID=$(echo "$PROPOSE_OUT" | grep -E "Proposal ID:" | sed -n 's/.*Proposal ID: \([0-9]*\).*/\1/p' | head -1)
[[ -z "$PROPOSAL_ID" ]] && { echo "$PROPOSE_OUT"; fail "Could not parse Proposal ID"; }
ok "Proposal ID: $PROPOSAL_ID"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 8: Vote (For)
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 8: Vote For"

# If VOTING_DELAY > 0, wait for proposal to become Active
if [[ "$VOTING_DELAY" -gt 0 ]]; then
    wait_blocks "$VOTING_DELAY"
fi

python3 "$PROJECT_ROOT/tools/vote.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" \
    --support 1 \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Vote cast (support=1 For)"

python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 | tail -15

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 9: Wait voting period → Succeeded
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 9: Wait for voting to end + finalize"
wait_blocks "$((VOTING_PERIOD + 1))"

python3 "$PROJECT_ROOT/tools/finalize_proposal.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Finalize submitted"

STATE_NOW=$(python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 \
    | grep -E "^State:" | awk '{print $2}')
ok "Post-finalize state: $STATE_NOW"

if [[ "$STATE_NOW" != "Succeeded" ]]; then
    warn "Expected Succeeded — proposal may have been Defeated due to zero voting power."
    warn "Check EVM↔hotkey association: voter with 0 power cannot pass proposals."
    python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
        --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 | tail -15
    log "E2E HALTED at Phase 9 (proposal not Succeeded)"
    exit 2
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 10: Queue
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 10: Queue"
python3 "$PROJECT_ROOT/tools/queue_proposal.py" "$GOVERNOR_ADDR" \
    --type native \
    --amount "$TRANSFER_AMOUNT" \
    --recipient "$RECIPIENT_ADDR" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" 2>&1 | tail -5
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
python3 "$PROJECT_ROOT/tools/execute_proposal.py" "$GOVERNOR_ADDR" \
    --type native \
    --amount "$TRANSFER_AMOUNT" \
    --recipient "$RECIPIENT_ADDR" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Executed"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 13: Verify recipient balance
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 13: Verify balance"
RECIPIENT_BAL_AFTER=$(cast balance "$RECIPIENT_ADDR" --rpc-url "$RPC_URL" --ether)
ok "Recipient balance after: $RECIPIENT_BAL_AFTER TAO"

DELTA=$(python3 -c "print(float('$RECIPIENT_BAL_AFTER') - float('$RECIPIENT_BAL_BEFORE'))")
ok "Delta: $DELTA TAO (expected: $TRANSFER_AMOUNT)"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

log "SUMMARY"
echo ""
echo "  Chain:               $RPC_URL"
echo "  Subnet netuid:       $NETUID"
echo "  Validator hotkey:    $HOTKEY_SS58"
echo "  Vault:               $VAULT_ADDR"
echo "  Governor:            $GOVERNOR_ADDR"
echo "  Proposal ID:         $PROPOSAL_ID"
echo "  Description:         $DESCRIPTION"
echo ""
echo "  Recipient:           $RECIPIENT_ADDR"
echo "  Balance before:      $RECIPIENT_BAL_BEFORE TAO"
echo "  Balance after:       $RECIPIENT_BAL_AFTER TAO"
echo "  Delta:               $DELTA TAO"
echo ""

DELTA_MATCHES=$(python3 -c "print('true' if abs(float('$DELTA') - float('$TRANSFER_AMOUNT')) < 0.0001 else 'false')")
if [[ "$DELTA_MATCHES" == "true" ]]; then
    ok "Native transfer E2E PASSED ✓"
else
    fail "Native transfer E2E FAILED — delta mismatch"
fi
