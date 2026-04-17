#!/usr/bin/env python3
"""
CLI for calling: castVote(uint256 proposalId, uint8 support)

Only support=1 (For/Yes) is accepted by the controller. Against and Abstain
revert with InvalidVoteSupport.
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
    parser = argparse.ArgumentParser(description="Cast Yes Vote on Proposal")
    parser.add_argument("contract", help="Governor contract address")
    parser.add_argument("--proposal-id", required=True, type=int)
    parser.add_argument("--support", type=int, default=1,
                        help="Only 1 (For/Yes) is accepted. Default: 1")

    add_web3_arguments(parser)
    args = parser.parse_args()

    if args.support != 1:
        sys.exit("Controller accepts only support=1 (Yes). Against/Abstain are disabled.")

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