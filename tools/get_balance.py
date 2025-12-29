#!/usr/bin/env python3
"""
CLI to check native balance (TAO) of any address.
"""

import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider

def main():
    parser = argparse.ArgumentParser(description="Get Account Balance")
    parser.add_argument("address", help="Address to check (Wallet or Contract)")
    parser.add_argument("--rpc-url", required=True)
    args = parser.parse_args()

    # 1. Connect
    try:
        w3 = get_web3_provider(args.rpc_url)
    except Exception as e:
        sys.exit(f"RPC Connection Error: {e}")

    # 2. Resolve Address
    if not w3.is_address(args.address):
        sys.exit("Invalid address format")

    target_address = w3.to_checksum_address(args.address)

    # 3. Get Balance
    try:
        # Returns balance in Wei (10^18)
        balance_wei = w3.eth.get_balance(target_address)
        balance_tao = w3.from_wei(balance_wei, 'ether')
    except Exception as e:
        sys.exit(f"Error fetching balance: {e}")

    print("-" * 40)
    print(f"BALANCE CHECK")
    print("-" * 40)
    print(f"Target:  {target_address}")
    print("-" * 40)
    print(f"TAO:     {balance_tao}")
    print(f"Wei/Rao: {balance_wei}")
    print("-" * 40)

if __name__ == "__main__":
    main()