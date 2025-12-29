#!/usr/bin/env python3
"""
CLI for calling: setVotingPower(uint16 netuid, bytes32 key, uint256 amount)
"""

import argparse
import os
import sys
from pathlib import Path

# Add the tools directory to sys.path
current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def main():
    parser = argparse.ArgumentParser(description="Set Mock Voting Power")
    parser.add_argument("contract", help="MockBittensorVotes contract address")
    parser.add_argument("--hotkey", required=True, help="EVM Address (0x...) to act as bytes32 key")
    parser.add_argument("--amount", required=True, type=float, help="Amount in TAO")
    parser.add_argument("--netuid", default=1, type=int)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)
    parser.add_argument("--force-gas-price-gwei", type=float, help="Force a specific Gas Price in Gwei")
    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    if not private_key:
        raise SystemExit("Error: Set PRIVATE_KEY env var or pass --private-key")

    # 1. Setup Web3 & Account
    try:
        w3 = get_web3_provider(args.rpc_url)
        account = w3.eth.account.from_key(private_key)

        print(f"--- WALLET INFO ---")
        print(f"Address: {account.address}")
    except Exception as e:
        print(f"CRITICAL ERROR connecting to Web3: {e}", file=sys.stderr)
        sys.exit(1)

    # 2. Prepare Data
    try:
        # Convert address to bytes32 (left padded)
        if args.hotkey.startswith("0x"):
            clean_hex = args.hotkey[2:]
        else:
            clean_hex = args.hotkey

        hotkey_bytes32 = bytes.fromhex(clean_hex.zfill(64))

        # 9 decimals logic as per example
        amount_raw = int(args.amount * 1_000_000_000)
    except ValueError as e:
        print(f"CRITICAL ERROR converting data: {e}", file=sys.stderr)
        sys.exit(1)

    # 3. Load Contract
    try:
        # Assuming artifact is in out/MockBittensorVotes.sol/MockBittensorVotes.json
        artifact_path = current_dir.parent / "out" / "MockBittensorVotes.sol" / "MockBittensorVotes.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        print(f"CRITICAL ERROR loading contract: {e}", file=sys.stderr)
        sys.exit(1)

    # 4. Execute
    fn = contract.functions.setVotingPower(args.netuid, hotkey_bytes32, amount_raw)

    print("--- GAS & COST CALCULATION ---")
    try:
        gas_estimate = fn.estimate_gas({"from": account.address})
        gas_limit = int(gas_estimate * 1.2)
        print(f"Gas Limit (Estimated): {gas_limit}")

        if args.force_gas_price_gwei:
            gas_price = w3.to_wei(args.force_gas_price_gwei, 'gwei')
            print(f"Gas Price (FORCED):    {args.force_gas_price_gwei} Gwei")
        else:
            gas_price = w3.eth.gas_price
            print(f"Gas Price (Node):      {w3.from_wei(gas_price, 'gwei'):.2f} Gwei")

    except Exception as exc:
        print(f"Gas estimation warning: {exc}. Using fallback.", file=sys.stderr)
        gas_limit = 500_000
        gas_price = w3.to_wei(100, 'gwei')

    nonce = w3.eth.get_transaction_count(account.address, "pending")

    tx = fn.build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": gas_limit,
        "gasPrice": gas_price,
        "chainId": w3.eth.chain_id,
        "value": 0,
    })

    print(f"Sending transaction (Nonce: {nonce})...")
    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)

    try:
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print(f"Sent tx: {tx_hash.hex()}")
    except Exception as e:
        print(f"Transaction failed locally: {e}")
        sys.exit(1)

    print("Waiting for receipt...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    if receipt["status"] == 1:
        print(f"SUCCESS! Block: {receipt['blockNumber']}, Gas Used: {receipt['gasUsed']}")
    else:
        print("FAILED!")

if __name__ == "__main__":
    main()