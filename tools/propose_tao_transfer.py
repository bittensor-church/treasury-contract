#!/usr/bin/env python3
"""
CLI to propose a NATIVE TAO Transfer from the Vault.
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
from utils.gov_utils import build_native_transfer_calldata


def main():
    parser = argparse.ArgumentParser(description="Propose Batch: Native TAO Transfer")

    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("--recipient", required=True, help="Recipient EVM Address (0x...)")
    parser.add_argument("--amount", required=True, type=float, help="Amount of TAO")
    parser.add_argument("--description", required=True, help="Proposal Description")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    # Native tokens usually use 18 decimals (ether standard)
    amount_wei = w3.to_wei(str(args.amount), 'ether')

    print(f"--- BUILDING PROPOSAL: NATIVE TRANSFER ---")
    print(f"Recipient: {args.recipient}")
    print(f"Amount:    {args.amount} TAO ({amount_wei} Wei)")

    targets, values, calldatas = build_native_transfer_calldata(w3, args, amount_wei)

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
        gas_limit_fallback=500_000
    )

    try:
        logs = governor.events.ProposalCreated().process_receipt(receipt)
        if logs:
            print(f"Proposal ID: {logs[0]['args']['proposalId']}")
    except Exception:
        pass

if __name__ == "__main__":
    main()