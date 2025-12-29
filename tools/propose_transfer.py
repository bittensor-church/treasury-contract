#!/usr/bin/env python3
"""
CLI for calling: propose(address[] targets, uint256[] values, bytes[] calldatas, string description)
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
    parser = argparse.ArgumentParser(description="Submit Governance Proposal")
    parser.add_argument("contract", help="Governor contract address")
    parser.add_argument("--recipient", required=True, help="Recipient address")
    parser.add_argument("--amount", required=True, type=float, help="Amount to transfer (TAO)")
    parser.add_argument("--description", required=True, help="Proposal description")
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
        print(f"--- WALLET INFO ---")
        print(f"Address: {account.address}")
    except Exception as e:
        print(f"CRITICAL ERROR connecting to Web3: {e}", file=sys.stderr)
        sys.exit(1)

    # Prepare Proposal Data
    targets = [Web3.to_checksum_address(args.recipient)]
    # EVM native transfer uses 18 decimals (Wei)
    values = [w3.to_wei(args.amount, 'ether')]
    calldatas = [b""]
    description = args.description

    print(f"Target: {targets[0]}")
    print(f"Value:  {values[0]} (Wei/Rao)")

    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        print(f"CRITICAL ERROR loading contract: {e}", file=sys.stderr)
        sys.exit(1)

    fn = contract.functions.propose(targets, values, calldatas, description)

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
        gas_limit = 1_000_000
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
        print(f"SUCCESS! Block: {receipt['blockNumber']}")
        # Try to parse Proposal ID
        try:
            logs = contract.events.ProposalCreated().process_receipt(receipt)
            if logs:
                print(f"Proposal ID: {logs[0]['args']['proposalId']}")
        except:
            pass
    else:
        print("FAILED!")

if __name__ == "__main__":
    main()