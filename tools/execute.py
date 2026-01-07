#!/usr/bin/env python3
"""
CLI for calling: execute(address[] targets, uint256[] values, bytes[] calldatas, bytes32 descriptionHash)
Updated to support generic calldata.
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
    parser.add_argument("--recipient", required=True, help="Target Address (Vault)")
    parser.add_argument("--amount", default=0.0, type=float, help="Value in TAO (default 0)")
    parser.add_argument("--calldata", default="0x", help="Hex string of calldata")
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

    # Reconstruct Data
    targets = [Web3.to_checksum_address(args.recipient)]
    values = [w3.to_wei(args.amount, 'ether')]

    cd_hex = args.calldata
    if cd_hex.startswith("0x"):
        cd_hex = cd_hex[2:]
    calldata_bytes = bytes.fromhex(cd_hex)
    calldatas = [calldata_bytes]

    description_hash = Web3.keccak(text=args.description)

    print(f"--- EXECUTING PROPOSAL ---")
    print(f"  Target: {targets[0]}")
    print(f"  Calldata Size: {len(calldata_bytes)}")

    fn = governor.functions.execute(targets, values, calldatas, description_hash)

    try:
        gas_estimate = fn.estimate_gas({"from": account.address})
        gas_limit = int(gas_estimate * 2.0)
        gas_price = w3.to_wei(args.force_gas_price_gwei, 'gwei') if args.force_gas_price_gwei else w3.eth.gas_price
    except Exception as e:
        print(f"Gas Estimate failed ({e}), using safe fallback")
        gas_limit = 5_000_000
        gas_price = w3.to_wei(100, 'gwei')

    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx = fn.build_transaction({
        "from": account.address, "nonce": nonce, "gas": gas_limit, "gasPrice": gas_price, "chainId": w3.eth.chain_id, "value": 0
    })

    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"Sent tx: {tx_hash.hex()}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if receipt["status"] == 1:
        print("Proposal EXECUTED! Stake changes should be reflected.")
    else:
        print("Execution FAILED.")

if __name__ == "__main__":
    main()