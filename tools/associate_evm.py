#!/usr/bin/env python3
"""
Associate EVM address with a Bittensor hotkey.
This enables EVM-based voting in the Treasury governance system.

Flow:
1. Get current block from chain
2. Create message: "associate evm: <coldkey>:<evm_address>:<block>"
3. Sign with EVM key (EIP-191)
4. Submit associate_evm_key extrinsic

Usage:
    python associate_evm.py \
        --rpc-url http://localhost:9944 \
        --private-key <EVM_PRIVATE_KEY> \
        --coldkey <SS58_COLDKEY> \
        --hotkey <SS58_HOTKEY>
"""

import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.common import add_web3_arguments, setup_web3_with_account

try:
    from substrateinterface import SubstrateInterface, Keypair
    from eth_account.messages import encode_defunct
except ImportError:
    sys.exit("Please install: pip install substrate-interface eth-account")


def main():
    parser = argparse.ArgumentParser(description="Associate EVM address with Bittensor hotkey")
    parser.add_argument("--coldkey", required=True, help="Coldkey SS58 address (owner of hotkey)")
    parser.add_argument("--hotkey", required=True, help="Hotkey SS58 address to associate")
    parser.add_argument("--coldkey-seed", help="Coldkey seed phrase (or set COLDKEY_SEED env)")
    
    add_web3_arguments(parser)
    args = parser.parse_args()

    # Setup Web3 for EVM
    w3, evm_account = setup_web3_with_account(args)
    evm_address = evm_account.address
    
    print(f"{'='*50}")
    print(f"EVM ASSOCIATION")
    print(f"{'='*50}")
    print(f"Coldkey: {args.coldkey}")
    print(f"Hotkey:  {args.hotkey}")
    print(f"EVM:     {evm_address}")
    print(f"{'='*50}")
    
    # Connect to Substrate
    substrate_url = args.rpc_url.replace("http://", "ws://").replace(":9944", ":9944")
    print(f"Connecting to Substrate: {substrate_url}")
    
    substrate = SubstrateInterface(url=substrate_url)
    block_number = substrate.get_block_number(substrate.get_chain_head())
    print(f"Current block: {block_number}")
    
    # Create and sign message (EIP-191)
    message = f"associate evm: {args.coldkey}:{evm_address}:{block_number}"
    print(f"Message: {message}")
    
    signed = evm_account.sign_message(encode_defunct(text=message))
    signature = signed.signature.hex()
    if not signature.startswith("0x"):
        signature = "0x" + signature
    print(f"Signature: {signature[:20]}...")
    
    # Get coldkey keypair
    import os
    coldkey_seed = args.coldkey_seed or os.getenv("COLDKEY_SEED")
    if not coldkey_seed:
        sys.exit("ERROR: Set --coldkey-seed or COLDKEY_SEED env var")
    
    coldkey_keypair = Keypair.create_from_uri(coldkey_seed)
    
    # Submit extrinsic
    print(f"\nSubmitting associate_evm_key extrinsic...")
    
    call = substrate.compose_call(
        call_module="SubtensorModule",
        call_function="associate_evm_key",
        call_params={
            'hotkey': args.hotkey,
            'evm_address': evm_address,
            'block_number': block_number,
            'signature': signature
        }
    )
    
    extrinsic = substrate.create_signed_extrinsic(call=call, keypair=coldkey_keypair)
    receipt = substrate.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    
    if receipt.is_success:
        print(f"\n✅ EVM Association successful!")
        print(f"   Block: {receipt.block_hash}")
        print(f"   EVM {evm_address} → Hotkey {args.hotkey}")
    else:
        print(f"\n❌ Association failed: {receipt.error_message}")
        sys.exit(1)


if __name__ == "__main__":
    main()
