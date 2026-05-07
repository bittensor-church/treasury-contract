#!/usr/bin/env bash
# ============================================================================
# Treasury Contract — ERC20 Transfer E2E Test (Local Chain)
# ============================================================================
#
# Same governance flow as localnet-e2e-native.sh, but transfers a MockERC20
# token from test/Mocks.sol instead of native TAO.
#
# Extra phases vs native:
#   5b. Deploy MockERC20
#   5c. Mint tokens → vault
#   13. Verify recipient ERC20 balance (not native balance)
#
# State file is shared with native (/tmp/treasury-e2e-state.env) — runs after
# a successful native setup will reuse subnet/hotkey/vault/governor. ERC20
# contract address is appended on first erc20 run and reused thereafter.
#
# Usage:
#   ./scripts/localnet-e2e-erc20.sh              # full setup + flow
#   REUSE_SETUP=1 ./scripts/localnet-e2e-erc20.sh  # reuse subnet/deploy/ERC20
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

CHAIN_ENDPOINT="${CHAIN_ENDPOINT:-ws://127.0.0.1:9944}"
RPC_URL="${RPC_URL:-http://127.0.0.1:9944}"

ALICE_WALLET="${ALICE_WALLET:-alice}"
ALICE_HOTKEY_NAME="${ALICE_HOTKEY_NAME:-default}"
ALICE_COLDKEY_SEED="0xe5be9a5092b81bca64be81d212e7f2f9eba183bb7a90954f7b76361f6edb5c0a"

DEPLOYER_ADDR="${DEPLOYER_ADDR:-0x509F12D8f6a0fE446055307f3dF2e10245C72494}"
DEPLOYER_PK="${DEPLOYER_PK:-0x2406c650b21d05b4057cc505e78e2f3e8db513a68c26b99cd030cc2f6c88445b}"
DEPLOYER_SS58="${DEPLOYER_SS58:-5DCcvGJKfNX16RWpbyvaYBTxFHexCh2wxGfLqS9BsX5GmaSA}"

VALIDATOR_HOTKEY_NAME="${VALIDATOR_HOTKEY_NAME:-e2e_validator}"

FUND_DEPLOYER_TAO=10000
STAKE_AMOUNT="${STAKE_AMOUNT:-5000}"
VAULT_FUND_AMOUNT="${VAULT_FUND_AMOUNT:-10}"

# ERC20-specific
ERC20_MINT_AMOUNT="${ERC20_MINT_AMOUNT:-1000}"      # tokens minted to vault (18-dec)
TRANSFER_AMOUNT="${TRANSFER_AMOUNT:-50}"            # tokens proposed to transfer

RECIPIENT_ADDR="${RECIPIENT_ADDR:-0xd10375caed456c5902D7B155117Dd155398145C7}"

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

DESCRIPTION="E2E ERC20 Transfer Test"

EVM_FLAGS="--legacy --gas-price 10000000000"
FORGE_FLAGS="$EVM_FLAGS --gas-limit 5000000 --broadcast"
CAST_FLAGS="$EVM_FLAGS --gas-limit 500000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

STATE_FILE="${STATE_FILE:-/tmp/treasury-e2e-state.env}"
REUSE_SETUP="${REUSE_SETUP:-0}"

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

read_hotkey_pubkey() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('publicKey',''))"
}
read_hotkey_ss58() {
    python3 -c "import json; print(json.load(open('$HOME/.bittensor/wallets/$1/hotkeys/$2')).get('ss58Address',''))"
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

# Append/update a KEY=VALUE line in the state file.
update_state() {
    local KEY="$1"
    local VALUE="$2"
    if [[ -f "$STATE_FILE" ]] && grep -q "^${KEY}=" "$STATE_FILE"; then
        # Portable in-place update (macOS sed requires '' arg after -i)
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

if [[ ! -f "$PROJECT_ROOT/out/TreasuryController.sol/TreasuryController.json" ]] ||
   [[ ! -f "$PROJECT_ROOT/out/Mocks.sol/MockERC20.json" ]]; then
    log "Building contracts (forge build)"
    (cd "$PROJECT_ROOT" && forge build --quiet) || fail "forge build failed"
    ok "Compiled"
fi

# ─── Load cached setup ───────────────────────────────────────────────────────

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
    [[ -n "${ERC20_ADDR:-}" ]] && ok "  erc20=$ERC20_ADDR"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0: Fund deployer
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 0: Fund deployer"

# Top up Alice via sudo if low (subnet burn cost grows unboundedly across runs).
ALICE_SS58_DEV="5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
ALICE_BAL_RAO=$(python3 -c "
from substrateinterface import SubstrateInterface
si = SubstrateInterface(url='$CHAIN_ENDPOINT')
print(si.query('System','Account',['$ALICE_SS58_DEV']).value['data']['free'])
" 2>/dev/null || echo 0)
ALICE_MIN_RAO=$((500 * 10**15))
ALICE_TOP_RAO=$((1000 * 10**15))
if [[ -n "$ALICE_BAL_RAO" && "$ALICE_BAL_RAO" -lt "$ALICE_MIN_RAO" ]]; then
    warn "Alice balance low ($((ALICE_BAL_RAO / 10**9)) TAO), topping up via sudo..."
    python3 - <<PYEOF
from substrateinterface import SubstrateInterface, Keypair
si = SubstrateInterface(url='$CHAIN_ENDPOINT')
alice = Keypair.create_from_uri('//Alice')
inner = si.compose_call('Balances', 'force_set_balance',
                        {'who': alice.ss58_address, 'new_free': $ALICE_TOP_RAO})
sudo = si.compose_call('Sudo', 'sudo', {'call': inner})
ext = si.create_signed_extrinsic(call=sudo, keypair=alice)
r = si.submit_extrinsic(ext, wait_for_inclusion=True)
print('  topup block:', r.block_hash)
PYEOF
    ok "Alice topped up to $((ALICE_TOP_RAO / 10**15))M TAO"
else
    ok "Alice balance: $((ALICE_BAL_RAO / 10**9)) TAO"
fi

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
# PHASE 1: Subnet
# ═════════════════════════════════════════════════════════════════════════════

if [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 1: SKIPPED (REUSE_SETUP=1, netuid=$NETUID from cache)"
elif [[ -n "${EXISTING_NETUID:-}" ]]; then
    log "Phase 1: Using existing subnet (netuid=$EXISTING_NETUID)"
    NETUID="$EXISTING_NETUID"
    ok "netuid $NETUID (existing)"
else
    log "Phase 1: Create subnet + start emissions"
    NETUID=""
    for attempt in 1 2 3 4 5; do
        OUTPUT=$(printf '\n\n\n\n\n\n\n\n\n\n' | btcli_cmd subnets create \
            --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" \
            --no-prompt --no-mev-protection --subnet-name "treasury_e2e" 2>&1)
        NETUID=$(echo "$OUTPUT" | sed -n 's/.*netuid: \([0-9]*\).*/\1/p' | tail -1)
        [[ -n "$NETUID" ]] && break
        warn "subnets create attempt $attempt failed (likely mortal-era expiry), retrying..."
        sleep 6
    done
    [[ -z "$NETUID" ]] && { echo "$OUTPUT"; fail "Could not extract netuid after retries"; }
    ok "Created subnet netuid=$NETUID"

    btcli_cmd subnets start --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --hotkey "$ALICE_HOTKEY_NAME" --no-prompt 2>&1 | tail -1
    ok "Emissions started"

    btcli_cmd sudo set --netuid "$NETUID" \
        --wallet-name "$ALICE_WALLET" --param max_regs_per_block --value 8 --no-prompt 2>&1 | tail -1 || true
    ok "max_regs_per_block → 8"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: Validator hotkey
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
# PHASE 3: Stake
# Direct SubtensorModule.add_stake (bypasses btcli's MEV-shield path).
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
# VotingPowerTrackingEnabled defaults to false on fresh subnets → precompile
# 0x80D returns 0 and every finalize() ends Defeated. Must enable via sudo.
# VotingPowerEmaAlpha default 0.00357e18 = 2-week e-folding; bump to 0.5e18 so
# localnet accumulates voting power within one test run.
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
# PHASE 4: EVM ↔ hotkey association (always runs)
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 4: Associate EVM → hotkey (for real voting power)"

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
    warn "associate_evm failed (rate-limit if already done, otherwise investigate)."
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

    DEPLOY_OUT=$(cd "$PROJECT_ROOT" && forge script script/Deploy.s.sol:DeployGovernance \
        --rpc-url "$RPC_URL" --broadcast --legacy -vv 2>&1)

    VAULT_ADDR=$(echo "$DEPLOY_OUT" | grep -E "Vault deployed at:" | sed -n 's/.*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)
    GOVERNOR_ADDR=$(echo "$DEPLOY_OUT" | grep -E "Governor deployed at:" | sed -n 's/.*\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)

    [[ -z "$VAULT_ADDR" ]] && { echo "$DEPLOY_OUT" | tail -30; fail "Could not parse Vault address"; }
    [[ -z "$GOVERNOR_ADDR" ]] && { echo "$DEPLOY_OUT" | tail -30; fail "Could not parse Governor address"; }

    ok "Vault:    $VAULT_ADDR"
    ok "Governor: $GOVERNOR_ADDR"

    VAULT_SS58=$(h160_to_ss58 "$VAULT_ADDR")
    ok "Vault SS58: $VAULT_SS58"

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

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5b: Deploy MockERC20 (cached per setup)
# ═════════════════════════════════════════════════════════════════════════════

if [[ -n "${ERC20_ADDR:-}" ]] && [[ "$REUSE_SETUP" == "1" ]]; then
    log "Phase 5b: SKIPPED (ERC20 from cache: $ERC20_ADDR)"
else
    log "Phase 5b: Deploy MockERC20"

    # forge create writes deployed address to stdout ("Deployed to: 0x...")
    ERC20_DEPLOY_OUT=$(cd "$PROJECT_ROOT" && forge create test/Mocks.sol:MockERC20 \
        --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" \
        --broadcast --legacy --gas-price 10000000000 --gas-limit 5000000 2>&1)
    ERC20_ADDR=$(echo "$ERC20_DEPLOY_OUT" | grep -E "Deployed to:" | awk '{print $3}')
    [[ -z "$ERC20_ADDR" ]] && { echo "$ERC20_DEPLOY_OUT" | tail -20; fail "Could not parse MockERC20 address"; }
    ok "MockERC20: $ERC20_ADDR"

    update_state "ERC20_ADDR" "$ERC20_ADDR"
    ok "Saved ERC20 address to $STATE_FILE"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6: Mint ERC20 to vault (top-up if below target)
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 6: Mint ERC20 to vault (target: $ERC20_MINT_AMOUNT tokens)"

MINT_WEI=$(cast to-wei "$ERC20_MINT_AMOUNT" ether)

VAULT_ERC20_BAL_WEI=$(cast call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$VAULT_ADDR" \
    --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}' || echo "0")
# cast prints decimal — strip any bracket formatting just in case
VAULT_ERC20_BAL_WEI="${VAULT_ERC20_BAL_WEI//[^0-9]/}"

BAL_GE_TARGET=$(python3 -c "print('1' if int('${VAULT_ERC20_BAL_WEI:-0}') >= int('$MINT_WEI') else '0')")

if [[ "$BAL_GE_TARGET" == "1" ]]; then
    ok "Vault already has enough ERC20 (${VAULT_ERC20_BAL_WEI} wei ≥ $MINT_WEI wei target)"
else
    cast send "$ERC20_ADDR" "mint(address,uint256)" "$VAULT_ADDR" "$MINT_WEI" \
        --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" \
        --legacy --gas-price 10000000000 --gas-limit 200000 2>&1 | tail -3
    ok "Minted $ERC20_MINT_AMOUNT tokens → vault"
fi

VAULT_ERC20_BAL_WEI=$(cast call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$VAULT_ADDR" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
VAULT_ERC20_BAL=$(cast from-wei "$VAULT_ERC20_BAL_WEI")
ok "Vault ERC20 balance: $VAULT_ERC20_BAL tokens"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 7: Propose ERC20 transfer
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 7: Propose ERC20 transfer ($TRANSFER_AMOUNT tokens → $RECIPIENT_ADDR)"

RECIPIENT_ERC20_BAL_BEFORE_WEI=$(cast call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$RECIPIENT_ADDR" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
RECIPIENT_ERC20_BAL_BEFORE=$(cast from-wei "$RECIPIENT_ERC20_BAL_BEFORE_WEI")
ok "Recipient ERC20 balance before: $RECIPIENT_ERC20_BAL_BEFORE tokens"

PROPOSE_OUT=$(python3 "$PROJECT_ROOT/tools/propose_proposal.py" "$GOVERNOR_ADDR" \
    --type erc20 \
    --token "$ERC20_ADDR" \
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
# PHASE 8: Vote For
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 8: Vote For"

if [[ "$VOTING_DELAY" -gt 0 ]]; then
    wait_blocks "$VOTING_DELAY"
fi

python3 "$PROJECT_ROOT/tools/vote.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --support 1 \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Vote cast (support=1 For)"

python3 "$PROJECT_ROOT/tools/get_proposal_state.py" "$GOVERNOR_ADDR" \
    --proposal-id "$PROPOSAL_ID" --rpc-url "$RPC_URL" 2>&1 | tail -15

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
    warn "Expected Succeeded — proposal may have been Defeated (check voting power)."
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
    --type erc20 \
    --token "$ERC20_ADDR" \
    --amount "$TRANSFER_AMOUNT" \
    --recipient "$RECIPIENT_ADDR" \
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
python3 "$PROJECT_ROOT/tools/execute_proposal.py" "$GOVERNOR_ADDR" \
    --type erc20 \
    --token "$ERC20_ADDR" \
    --amount "$TRANSFER_AMOUNT" \
    --recipient "$RECIPIENT_ADDR" \
    --description "$DESCRIPTION" \
    --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PK" 2>&1 | tail -5
ok "Executed"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 13: Verify recipient ERC20 balance
# ═════════════════════════════════════════════════════════════════════════════

log "Phase 13: Verify ERC20 balance"

RECIPIENT_ERC20_BAL_AFTER_WEI=$(cast call "$ERC20_ADDR" "balanceOf(address)(uint256)" "$RECIPIENT_ADDR" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
RECIPIENT_ERC20_BAL_AFTER=$(cast from-wei "$RECIPIENT_ERC20_BAL_AFTER_WEI")
ok "Recipient ERC20 balance after: $RECIPIENT_ERC20_BAL_AFTER tokens"

DELTA_WEI=$(python3 -c "print(int('$RECIPIENT_ERC20_BAL_AFTER_WEI') - int('$RECIPIENT_ERC20_BAL_BEFORE_WEI'))")
DELTA=$(cast from-wei "$DELTA_WEI")
ok "Delta: $DELTA tokens (expected: $TRANSFER_AMOUNT)"

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
echo "  MockERC20:           $ERC20_ADDR"
echo "  Proposal ID:         $PROPOSAL_ID"
echo "  Description:         $DESCRIPTION"
echo ""
echo "  Recipient:           $RECIPIENT_ADDR"
echo "  Balance before:      $RECIPIENT_ERC20_BAL_BEFORE tokens"
echo "  Balance after:       $RECIPIENT_ERC20_BAL_AFTER tokens"
echo "  Delta:               $DELTA tokens"
echo ""

EXPECTED_WEI=$(cast to-wei "$TRANSFER_AMOUNT" ether)
if [[ "$DELTA_WEI" == "$EXPECTED_WEI" ]]; then
    ok "ERC20 transfer E2E PASSED ✓"
else
    fail "ERC20 transfer E2E FAILED — delta mismatch (got $DELTA_WEI wei, expected $EXPECTED_WEI wei)"
fi
