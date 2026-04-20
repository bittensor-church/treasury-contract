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
    parser = argparse.ArgumentParser(description="Queue Typed Proposal")
    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("--type", required=True, choices=['native', 'alpha', 'erc20'], help="Proposal Type")
    parser.add_argument("--description", required=True, help="Exact Proposal Description string")
    parser.add_argument("--amount", required=True, type=float)
    parser.add_argument("--recipient", required=True, help="Recipient EVM or SS58 (for alpha)")
    parser.add_argument("--token", help="Token Address (ERC20 only)")
    parser.add_argument("--hotkey", help="Hotkey (hex 0x.. or SS58) — Alpha only")
    parser.add_argument("--origin-netuid", type=int, help="Origin NetUID (Alpha only)")
    parser.add_argument("--destination-netuid", type=int,
                        help="Destination NetUID (Alpha only, defaults to --origin-netuid)")
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
        fn = governor.functions.queueNativeTransfer(
            w3.to_checksum_address(args.recipient),
            amount_wei,
            args.description
        )
    elif args.type == 'erc20':
        amount_wei = w3.to_wei(str(args.amount), 'ether')
        fn = governor.functions.queueERC20Transfer(
            w3.to_checksum_address(args.token),
            w3.to_checksum_address(args.recipient),
            amount_wei,
            args.description
        )
    elif args.type == 'alpha':
        if args.origin_netuid is None or not args.hotkey:
            sys.exit("Error: --origin-netuid and --hotkey are required for Alpha proposals")

        dest_netuid = args.destination_netuid if args.destination_netuid is not None else args.origin_netuid
        amount_rao = int(args.amount * 1_000_000_000)
        destination_coldkey_b32 = decode_ss58_to_bytes32(args.recipient)
        hotkey_b32 = parse_hotkey(args.hotkey)

        fn = governor.functions.queueAlphaTransfer(
            destination_coldkey_b32,
            hotkey_b32,
            args.origin_netuid,
            dest_netuid,
            amount_rao,
            args.description
        )

    print(f"--- QUEUE: {args.type.upper()} TRANSFER ---")
    execute_transaction(w3, account, fn, force_gas_price_gwei=args.force_gas_price_gwei)

if __name__ == "__main__":
    main()