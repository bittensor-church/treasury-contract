#!/bin/bash

export RPC_URL="https://test.chain.opentensor.ai"

export MIN_DELAY=1

if [ -f .env ]; then
    echo "Loading variables from .env..."
    export $(grep -v '^#' .env | xargs)
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "NO PRIVATE_KEY ENV SET."
     exit 1
fi

forge script script/DeployVaultOnly.s.sol:DeployVaultOnly \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --legacy \
    -vvvv

echo "--------------------------------------------------"
echo "Deployment finished."