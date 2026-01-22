#!/usr/bin/env python3
"""
CLI to QUEUE 'transferAlpha' proposal.
"""

import argparse
import sys
from pathlib import Path
from web3 import Web3

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import load_contract
from utils.common import setup_web3_with_account, add_web3_arguments
from utils.tx_handler import execute_transaction
from utils.gov_utils import build_transfer_alpha_calldata

def main():
    parser = argparse.ArgumentParser(description="Queue Transfer Alpha Proposal")

    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("staking_contract", help="Staking/Mock Contract Address (Target)")
    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--amount", required=True, type=float)
    parser.add_argument("--hotkey", required=True, help="Where the stake is at")
    parser.add_argument("--recipient", required=True, help="User Address (SS58)")
    parser.add_argument("--description", required=True, help="Must match proposal description EXACTLY")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)
    print(f"--- WALLET: {account.address} ---")

    print(f"--- RECONSTRUCTING CALLDATA ---")
    amount_wei = int(args.amount * 1_000_000_000)
    targets, values, calldatas = build_transfer_alpha_calldata(w3, args, amount_wei)

    description_hash = Web3.keccak(text=args.description)
    print(f"Queueing Proposal with {len(targets)} actions...")
    print(f"Description Hash: {description_hash.hex()}")

    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.governor, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Load Error: {e}")

    fn = contract.functions.queue(targets, values, calldatas, description_hash)

    execute_transaction(w3, account, fn)

if __name__ == "__main__":
    main()