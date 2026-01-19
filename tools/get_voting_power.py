#!/usr/bin/env python3
"""
CLI to query voting power AND total voting power from MockBittensorVotes contract.
"""

import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import load_contract
from utils.common import setup_web3_connection, add_web3_arguments

def main():
    parser = argparse.ArgumentParser(description="Read Voting Power & Percentage")
    parser.add_argument("contract", help="MockBittensorVotes contract address")
    parser.add_argument("--hotkey", required=True, help="Address/Hotkey (0x...)")
    parser.add_argument("--netuid", default=1, type=int)

    add_web3_arguments(parser, requires_private_key=False)
    args = parser.parse_args()

    try:
        w3 = setup_web3_connection(args.rpc_url)
    except Exception as e:
        sys.exit(f"RPC Connection Error: {e}")

    clean_hotkey = args.hotkey.removeprefix("0x")

    try:
        hotkey_bytes32 = bytes.fromhex(clean_hotkey.zfill(64))
    except ValueError:
        sys.exit("Invalid hotkey format. Use hex string.")

    try:
        artifact_path = current_dir.parent / "out" / "MockBittensorVotes.sol" / "MockBittensorVotes.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Load Error: {e}")

    try:
        power_raw = contract.functions.getVotingPower(args.netuid, hotkey_bytes32).call()
        total_raw = contract.functions.getTotalVotingPower(args.netuid).call()
    except Exception as e:
        sys.exit(f"Error calling contract functions: {e}")

    power_tao = power_raw / 1_000_000_000
    total_tao = total_raw / 1_000_000_000
    percentage = (power_raw / total_raw * 100) if total_raw > 0 else 0.0

    print("-" * 40)
    print(f"QUERY VOTING POWER")
    print("-" * 40)
    print(f"Contract: {args.contract}")
    print(f"NetUID:   {args.netuid}")
    print(f"Hotkey:   {args.hotkey}")
    print("-" * 40)
    print(f"My Power (TAO):    {power_tao:,.9f}")
    print(f"Total Power (TAO): {total_tao:,.9f}")
    print("-" * 40)
    print(f"Share (%):         {percentage:.4f}%")
    print("-" * 40)
    print(f"Raw My:    {power_raw}")
    print(f"Raw Total: {total_raw}")
    print("-" * 40)

if __name__ == "__main__":
    main()