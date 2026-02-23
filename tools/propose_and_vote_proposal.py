#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import load_contract
from utils.common import setup_web3_with_account, add_web3_arguments
from utils.tx_handler import execute_transaction
from utils.gov_utils import decode_ss58_to_bytes32, parse_hotkey

def main():
    parser = argparse.ArgumentParser(description="Propose & Vote Typed Proposal")
    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("--type", required=True, choices=['native', 'alpha', 'erc20'], help="Proposal Type")
    parser.add_argument("--description", required=True, help="Proposal Description")

    parser.add_argument("--amount", required=True, type=float)
    parser.add_argument("--recipient", required=True, help="Recipient EVM or SS58 (for alpha)")

    parser.add_argument("--token", help="Token Address (ERC20 only)")
    parser.add_argument("--staking-contract", help="Staking Address (Alpha only)")
    parser.add_argument("--netuid", type=int, help="NetUID (Alpha only)")
    parser.add_argument("--hotkey", help="Hotkey Hex (Alpha only)")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    try:
        gov_artifact = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        governor = load_contract(w3, args.governor, gov_artifact)
    except Exception as e:
        sys.exit(f"Error loading Governor: {e}")

    fn = None

    if args.type == 'native':
        amount_wei = w3.to_wei(str(args.amount), 'ether')
        fn = governor.functions.proposeAndVoteNativeTransfer(
            w3.to_checksum_address(args.recipient),
            amount_wei,
            args.description
        )

    elif args.type == 'erc20':
        if not args.token:
            sys.exit("Error: --token is required for ERC20 proposals")

        amount_wei = w3.to_wei(str(args.amount), 'ether')
        fn = governor.functions.proposeAndVoteERC20Transfer(
            w3.to_checksum_address(args.token),
            w3.to_checksum_address(args.recipient),
            amount_wei,
            args.description
        )

    elif args.type == 'alpha':
        if not args.staking_contract or args.netuid is None or not args.hotkey:
            sys.exit("Error: --staking-contract, --netuid, and --hotkey are required for Alpha proposals")

        amount_wei = int(args.amount * 1_000_000_000)
        recipient_bytes = decode_ss58_to_bytes32(args.recipient)
        hotkey_bytes = parse_hotkey(args.hotkey)

        fn = governor.functions.proposeAndVoteAlphaTransfer(
            w3.to_checksum_address(args.staking_contract),
            args.netuid,
            hotkey_bytes,
            w3.to_checksum_address(f"0x{recipient_bytes.hex()}"),
            amount_wei,
            args.description
        )

    print(f"--- PROPOSE & VOTE: {args.type.upper()} TRANSFER ---")
    receipt = execute_transaction(w3, account, fn, force_gas_price_gwei=args.force_gas_price_gwei)

    try:
        logs = governor.events.ProposalCreated().process_receipt(receipt)
        if logs:
            print(f"Proposal ID: {logs[0]['args']['proposalId']}")

        vote_logs = governor.events.VoteCast().process_receipt(receipt)
        if vote_logs:
            print(f"Vote Cast: Support={vote_logs[0]['args']['support']} (1=For)")
    except Exception:
        pass

if __name__ == "__main__":
    main()