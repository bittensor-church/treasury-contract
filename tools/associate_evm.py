#!/usr/bin/env python3
"""
Associate EVM address with a Bittensor hotkey.
This enables EVM-based voting in the Treasury governance system.

Pallet-subtensor `associate_evm_key(netuid, evm_key, block_number, signature)` requires:
  - origin = HOTKEY (signs the extrinsic, not coldkey)
  - signature = EIP-191 signature by EVM key of the message:
        hotkey_pubkey (32B) ++ keccak256(block_number as u64 LE bytes)

Usage:
    python associate_evm.py \\
        --rpc-url http://localhost:9944 \\
        --private-key <EVM_PRIVATE_KEY> \\
        --netuid <NETUID> \\
        --hotkey <SS58_HOTKEY> \\
        --hotkey-uri "<mnemonic | //Alice | 0x-seed>"
"""

import argparse
import os
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.common import add_web3_arguments, setup_web3_with_account

try:
    from substrateinterface import SubstrateInterface, Keypair
    from eth_account.messages import encode_defunct
    from eth_utils import keccak
except ImportError:
    sys.exit("Please install: pip install substrate-interface eth-account eth-utils")


def main():
    parser = argparse.ArgumentParser(description="Associate EVM address with Bittensor hotkey")
    parser.add_argument("--netuid", type=int, required=True, help="Subnet uid the hotkey is registered on")
    parser.add_argument("--hotkey", required=True, help="Hotkey SS58 address (must match --hotkey-uri)")
    parser.add_argument(
        "--hotkey-uri",
        help="Hotkey mnemonic / //Alice-style URI / hex seed (0x...). Env: HOTKEY_URI",
    )
    parser.add_argument("--ws-url", help="Substrate WS endpoint (default: derived from --rpc-url)")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, evm_account = setup_web3_with_account(args)
    evm_address = evm_account.address

    ws_url = args.ws_url or args.rpc_url.replace("http://", "ws://").replace("https://", "wss://")

    hotkey_uri = args.hotkey_uri or os.getenv("HOTKEY_URI")
    if not hotkey_uri:
        sys.exit("ERROR: Set --hotkey-uri or HOTKEY_URI env var (mnemonic / //Alice / 0x-seed)")

    hotkey_keypair = Keypair.create_from_uri(hotkey_uri)
    if hotkey_keypair.ss58_address != args.hotkey:
        sys.exit(
            f"ERROR: --hotkey-uri derives SS58 {hotkey_keypair.ss58_address}, "
            f"but --hotkey is {args.hotkey}"
        )

    print("=" * 50)
    print("EVM ASSOCIATION")
    print("=" * 50)
    print(f"Netuid:  {args.netuid}")
    print(f"Hotkey:  {args.hotkey}")
    print(f"EVM:     {evm_address}")
    print(f"WS:      {ws_url}")
    print("=" * 50)

    substrate = SubstrateInterface(url=ws_url)
    block_number = substrate.get_block_number(substrate.get_chain_head())
    print(f"Current block: {block_number}")

    # Build the message the pallet will hash:
    #   message = hotkey.public_key (32 B) ++ keccak256(SCALE(u64 block_number))
    # SCALE encoding of u64 is 8 bytes little-endian.
    block_number_scale = block_number.to_bytes(8, "little")
    block_hash = keccak(block_number_scale)
    message = bytes(hotkey_keypair.public_key) + block_hash
    assert len(message) == 64, f"message length {len(message)} != 64"

    # EIP-191 sign with the EVM key. eth_account wraps with
    # "\x19Ethereum Signed Message:\n" + len + body and hashes via keccak256 — identical to
    # pallet `hash_message_eip191`.
    signed = evm_account.sign_message(encode_defunct(primitive=message))
    signature_hex = signed.signature.hex()
    if not signature_hex.startswith("0x"):
        signature_hex = "0x" + signature_hex
    print(f"Signature: {signature_hex[:20]}...{signature_hex[-6:]}")

    print("\nSubmitting associate_evm_key extrinsic (origin = hotkey)...")
    call = substrate.compose_call(
        call_module="SubtensorModule",
        call_function="associate_evm_key",
        call_params={
            "netuid": args.netuid,
            "evm_key": evm_address,
            "block_number": block_number,
            "signature": signature_hex,
        },
    )

    extrinsic = substrate.create_signed_extrinsic(call=call, keypair=hotkey_keypair)
    receipt = substrate.submit_extrinsic(extrinsic, wait_for_inclusion=True)

    if receipt.is_success:
        print("\nEVM Association successful!")
        print(f"  Block: {receipt.block_hash}")
        print(f"  EVM {evm_address} -> Hotkey {args.hotkey} on netuid {args.netuid}")
    else:
        print(f"\nAssociation failed: {receipt.error_message}")
        sys.exit(1)


if __name__ == "__main__":
    main()
