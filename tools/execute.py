#!/usr/bin/env python3
"""
CLI to Execute a queued Proposal.
Requires exact same parameters as Propose.
"""

import argparse
import os
import sys
from pathlib import Path
from web3 import Web3

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def main():
    parser = argparse.ArgumentParser(description="Execute Proposal")
    parser.add_argument("contract", help="TreasuryController (Governor) Address")
    # Same args as propose
    parser.add_argument("--recipient", required=True)
    parser.add_argument("--amount-eth", required=True, type=float)
    parser.add_argument("--description", required=True)

    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)
    parser.add_argument("--force-gas-price-gwei", type=float)
    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    w3 = get_web3_provider(args.rpc_url)
    account = w3.eth.account.from_key(private_key)

    artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
    governor = load_contract(w3, args.contract, artifact_path)

    # Reconstruct Payload
    targets = [Web3.to_checksum_address(args.recipient)]
    values = [w3.to_wei(args.amount_eth, 'ether')]
    calldatas = [b""]
    description_hash = Web3.keccak(text=args.description)

    print(f"--- EXECUTING PROPOSAL ---")

    fn = governor.functions.execute(targets, values, calldatas, description_hash)

    try:
        gas_limit = int(fn.estimate_gas({"from": account.address}) * 1.2)
        gas_price = w3.to_wei(args.force_gas_price_gwei, 'gwei') if args.force_gas_price_gwei else w3.eth.gas_price
    except Exception as e:
        print(f"Gas Estimate failed ({e}), using safe fallback")
        gas_limit = 2_000_000 # High limit for execution
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

    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"Sent tx: {tx_hash.hex()}")
    w3.eth.wait_for_transaction_receipt(tx_hash)
    print("Proposal EXECUTED! Money should be moved.")

if __name__ == "__main__":
    main()