#!/bin/bash

export RPC_URL="https://test.chain.opentensor.ai"

export NETUID=1
export GOV_NAME="BittensorDAO"
export MIN_DELAY=30

export VOTING_DELAY=0

export VOTING_PERIOD=10

export PROPOSAL_THRESHOLD=0

export QUORUM_BPS=400

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
echo "--------------------------------------------------"

forge script script/DeployGovernance.s.sol:DeployGovernance \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --legacy \
    -vvvv

echo "--------------------------------------------------"
echo "Deployment finished."