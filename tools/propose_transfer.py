#!/usr/bin/env python3
"""
CLI to propose 'transferAlpha' (Atomic Stake Transfer) via Batch Proposal.
Uses LOW-LEVEL ABI encoding to bypass Web3.py version conflicts.
"""

import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import load_contract
from utils.common import setup_web3_with_account, add_web3_arguments
from utils.tx_handler import execute_transaction
from utils.gov_utils import build_transfer_alpha_calldata

def main():
    parser = argparse.ArgumentParser(description="Propose Batch: Move & Transfer Stake")

    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("staking_contract", help="Staking/Mock Contract Address (Target)")
    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--amount", required=True, type=float)
    parser.add_argument("--from-hotkey", required=True, help="Current Validator")
    parser.add_argument("--to-hotkey", required=True, help="New Validator")
    parser.add_argument("--recipient", required=True, help="User Address (EVM)")
    parser.add_argument("--description", required=True)

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    amount_wei = int(args.amount * 1_000_000_000_000_000_000)

    print(f"--- BUILDING PROPOSAL BATCH (LOW LEVEL) ---")
    targets, values, calldatas = build_transfer_alpha_calldata(w3, args, amount_wei)

    print(f"Submitting Batch Proposal with {len(targets)} actions...")

    try:
        gov_artifact = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        governor = load_contract(w3, args.governor, gov_artifact)
    except Exception as e:
        sys.exit(f"Error loading Governor ABI: {e}")

    fn = governor.functions.propose(targets, values, calldatas, args.description)

    receipt = execute_transaction(
        w3=w3,
        account=account,
        function_call=fn,
        force_gas_price_gwei=args.force_gas_price_gwei,
        gas_limit_fallback=1_000_000
    )

    try:
        logs = governor.events.ProposalCreated().process_receipt(receipt)
        if logs:
            print(f"Proposal ID: {logs[0]['args']['proposalId']}")
    except Exception:
        pass

if __name__ == "__main__":
    main()