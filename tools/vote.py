#!/usr/bin/env python3
"""
CLI for calling: castVote(uint256 proposalId, uint8 support)
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

def main():
    parser = argparse.ArgumentParser(description="Cast Vote on Proposal")
    parser.add_argument("contract", help="Governor contract address")
    parser.add_argument("--proposal-id", required=True, type=int)
    parser.add_argument("--support", required=True, type=int, help="0=Against, 1=For, 2=Abstain")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    print(f"--- WALLET INFO ---")
    print(f"Address: {account.address}")

    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"CRITICAL ERROR loading contract: {e}")

    fn = contract.functions.castVote(args.proposal_id, args.support)

    execute_transaction(
        w3=w3,
        account=account,
        function_call=fn,
        force_gas_price_gwei=args.force_gas_price_gwei,
        gas_limit_fallback=200_000
    )

if __name__ == "__main__":
    main()