#!/bin/bash
set -euo pipefail

# Localnet config
export RPC_URL="${RPC_URL:-http://localhost:9944}"

export NETUID="${NETUID:-2}"
export GOV_NAME="${GOV_NAME:-BittensorDAO}"
export MIN_DELAY="${MIN_DELAY:-1}"  # 1 block for testing

export VOTING_DELAY="${VOTING_DELAY:-0}"
export VOTING_PERIOD="${VOTING_PERIOD:-10}"  # 5 blocks for testing
export PROPOSAL_THRESHOLD="${PROPOSAL_THRESHOLD:-0}"
export QUORUM_BPS="${QUORUM_BPS:-100}"  # 1% for testing
export PROPOSAL_EXPIRATION="${PROPOSAL_EXPIRATION:-1000}"

export TAO_LIMIT="${TAO_LIMIT:-1000000000000000000000}"       # 1000 TAO (wei)
export ALPHA_LIMIT="${ALPHA_LIMIT:-5000000000000000000000}"   # 5000 α (wei)
export ERC20_LIMIT="${ERC20_LIMIT:-10000000000000000000000}"  # 10000 tokens (wei)
export LIMIT_RESET_PERIOD_MIN="${LIMIT_RESET_PERIOD_MIN:-10080}"  # 1 week

if [ -f .env ]; then
    echo "Loading variables from .env..."
    export $(grep -v '^#' .env | xargs)
fi

if [ -z "${PRIVATE_KEY:-}" ]; then
    echo "NO PRIVATE_KEY ENV SET."
    exit 1
fi

echo "--------------------------------------------------"
echo "Deploying Governance to: $RPC_URL"
echo "Governor Name:           $GOV_NAME"
echo "NetUID:                  $NETUID"
echo "Quorum (BPS):            $QUORUM_BPS"
echo "Voting Period:           $VOTING_PERIOD blocks"
echo "Min Delay (Timelock):    $MIN_DELAY blocks"
echo "--------------------------------------------------"

forge script script/Deploy.s.sol:DeployGovernance \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --legacy \
    -vvvv

echo "--------------------------------------------------"
echo "Deployment finished."
echo "--------------------------------------------------"