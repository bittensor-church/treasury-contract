#!/usr/bin/env python3
"""
CLI for calling: setVotingPower(uint16 netuid, bytes32 key, uint256 amount)
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
    parser = argparse.ArgumentParser(description="Set Mock Voting Power")
    parser.add_argument("contract", help="MockBittensorVotes contract address")
    parser.add_argument("--hotkey", required=True, help="EVM Address (0x...) to act as bytes32 key")
    parser.add_argument("--amount", required=True, type=float, help="Amount in TAO")
    parser.add_argument("--netuid", default=1, type=int)

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    print(f"--- WALLET INFO ---")
    print(f"Address: {account.address}")

    # Prepare Data
    try:
        clean_hotkey = args.hotkey.removeprefix("0x")
        hotkey_bytes32 = bytes.fromhex(clean_hotkey.zfill(64))
        # 9 decimals logic
        amount_raw = int(args.amount * 1_000_000_000)
    except ValueError as e:
        sys.exit(f"CRITICAL ERROR converting data: {e}")

    try:
        artifact_path = current_dir.parent / "out" / "MockBittensorVotes.sol" / "MockBittensorVotes.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"CRITICAL ERROR loading contract: {e}")

    fn = contract.functions.setVotingPower(args.netuid, hotkey_bytes32, amount_raw)

    execute_transaction(
        w3=w3,
        account=account,
        function_call=fn,
        force_gas_price_gwei=args.force_gas_price_gwei,
        gas_limit_fallback=500_000
    )

if __name__ == "__main__":
    main()