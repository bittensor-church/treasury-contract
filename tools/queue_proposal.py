#!/usr/bin/env python3
"""
CLI for calling: queue(address[] targets, uint256[] values, bytes[] calldatas, bytes32 descriptionHash)
Updated to support generic calldata (required for Staking operations).
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
    parser = argparse.ArgumentParser(description="Queue Proposal")
    parser.add_argument("contract", help="Governor contract address")
    parser.add_argument("--recipient", required=True, help="Target address (Vault)")
    parser.add_argument("--amount", default=0.0, type=float, help="Value in TAO (default 0 for function calls)")
    parser.add_argument("--calldata", default="0x", help="Hex string of calldata (default empty)")
    parser.add_argument("--description", required=True)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)
    parser.add_argument("--force-gas-price-gwei", type=float)
    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    if not private_key:
        raise SystemExit("Error: Set PRIVATE_KEY env var or pass --private-key")

    try:
        w3 = get_web3_provider(args.rpc_url)
        account = w3.eth.account.from_key(private_key)
        print(f"--- WALLET: {account.address} ---")
    except Exception as e:
        sys.exit(f"Web3 Error: {e}")

    # Reconstruct Data
    targets = [Web3.to_checksum_address(args.recipient)]
    values = [w3.to_wei(args.amount, 'ether')]

    # Process Calldata
    cd_hex = args.calldata
    if cd_hex.startswith("0x"):
        cd_hex = cd_hex[2:]
    calldata_bytes = bytes.fromhex(cd_hex)
    calldatas = [calldata_bytes]

    description_hash = Web3.keccak(text=args.description)

    print(f"Queueing Proposal:")
    print(f"  Target: {targets[0]}")
    print(f"  Value: {values[0]}")
    print(f"  Calldata Length: {len(calldata_bytes)} bytes")

    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Error: {e}")

    fn = contract.functions.queue(targets, values, calldatas, description_hash)

    # Exec Tx
    try:
        gas_estimate = fn.estimate_gas({"from": account.address})
        gas_limit = int(gas_estimate * 1.2)
        gas_price = w3.to_wei(args.force_gas_price_gwei, 'gwei') if args.force_gas_price_gwei else w3.eth.gas_price
    except:
        gas_limit = 500_000
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
        print(f"SUCCESS! Block: {receipt['blockNumber']}")
    else:
        print("FAILED!")

if __name__ == "__main__":
    main()