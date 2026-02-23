#!/bin/bash

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

if [ -f .env ]; then
    echo "Loading variables from .env..."
    export $(grep -v '^#' .env | xargs)
fi

if [ -z "$PRIVATE_KEY" ]; then
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