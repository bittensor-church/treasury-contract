#!/usr/bin/env python3
"""
CLI to query voting power from MockBittensorVotes contract.
"""

import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def main():
    parser = argparse.ArgumentParser(description="Read Voting Power")
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
    # function getVotingPower(uint16 netuid, bytes32 key) external view returns (uint256)
    power_raw = contract.functions.getVotingPower(args.netuid, hotkey_bytes32).call()

    # 9 decimals logic (RAO -> TAO for display)
    power_tao = power_raw / 1_000_000_000

    print("-" * 40)
    print(f"QUERY VOTING POWER")
    print("-" * 40)
    print(f"Contract: {args.contract}")
    print(f"NetUID:   {args.netuid}")
    print(f"Hotkey:   {args.hotkey}")
    print("-" * 40)
    print(f"Power (Raw): {power_raw}")
    print(f"Power (TAO): {power_tao}")
    print("-" * 40)

if __name__ == "__main__":
    main()