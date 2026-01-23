# tools/propose_erc20_transfer.py
#!/usr/bin/env python3
"""
CLI to propose an ERC20 Token Transfer from the Vault.
"""

import argparse
import sys
from pathlib import Path

from utils.contract_loader import load_contract
from utils.common import setup_web3_with_account, add_web3_arguments
from utils.tx_handler import execute_transaction
from utils.gov_utils import build_erc20_transfer_calldata

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

def main():
    parser = argparse.ArgumentParser(description="Propose Batch: ERC20 Transfer")

    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("token", help="ERC20 Token Contract Address")
    parser.add_argument("--recipient", required=True, help="Recipient EVM Address (0x...)")
    parser.add_argument("--amount", required=True, type=float, help="Amount of tokens")
    parser.add_argument("--decimals", default=18, type=int, help="Token decimals (default: 18)")
    parser.add_argument("--description", required=True, help="Proposal Description")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    # Calculate amount based on decimals
    amount_units = int(args.amount * (10 ** args.decimals))

    print(f"--- BUILDING PROPOSAL: ERC20 TRANSFER ---")
    print(f"Token:     {args.token}")
    print(f"Recipient: {args.recipient}")
    print(f"Amount:    {args.amount} (Raw: {amount_units})")

    targets, values, calldatas = build_erc20_transfer_calldata(w3, args, amount_units)

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