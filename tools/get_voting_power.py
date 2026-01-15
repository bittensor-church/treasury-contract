#!/usr/bin/env python3
"""
CLI to query voting power AND total voting power from MockBittensorVotes contract.
Calculates percentage share.
"""

import argparse
import sys
from pathlib import Path

# Add the tools directory to sys.path
current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def main():
    parser = argparse.ArgumentParser(description="Read Voting Power & Percentage")
    parser.add_argument("contract", help="MockBittensorVotes contract address")
    parser.add_argument("--hotkey", required=True, help="Address/Hotkey (0x...)")
    parser.add_argument("--netuid", default=1, type=int)
    parser.add_argument("--rpc-url", required=True)
    args = parser.parse_args()

    # 1. Connect
    try:
        w3 = get_web3_provider(args.rpc_url)
    except Exception as e:
        sys.exit(f"RPC Connection Error: {e}")

    # 2. Prepare Key
    if args.hotkey.startswith("0x"):
        clean_hex = args.hotkey[2:]
    else:
        clean_hex = args.hotkey

    try:
        # Convert address to bytes32 (left padded)
        hotkey_bytes32 = bytes.fromhex(clean_hex.zfill(64))
    except ValueError:
        sys.exit("Invalid hotkey format. Use hex string.")

    # 3. Load Contract
    try:
        artifact_path = current_dir.parent / "out" / "MockBittensorVotes.sol" / "MockBittensorVotes.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Load Error: {e}")

    # 4. Call (No Gas)
    try:
        # Get Individual Power
        power_raw = contract.functions.getVotingPower(args.netuid, hotkey_bytes32).call()

        # Get Total Power
        total_raw = contract.functions.getTotalVotingPower(args.netuid).call()
    except Exception as e:
        sys.exit(f"Error calling contract functions: {e}")

    # 5. Calculations
    power_tao = power_raw / 1_000_000_000
    total_tao = total_raw / 1_000_000_000

    percentage = 0.0
    if total_raw > 0:
        percentage = (power_raw / total_raw) * 100

    # 6. Display Results
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