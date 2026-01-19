#!/usr/bin/env python3
"""
CLI to fetch REAL stake breakdown directly from the Subtensor chain.
"""

import argparse
import sys
import bittensor as bt

def main():
    parser = argparse.ArgumentParser(description="Get Real Stake Breakdown from Subtensor")
    parser.add_argument("ss58_address", help="Coldkey SS58 Address (e.g. 5HTBix...)")
    parser.add_argument("--network", default="test", help="Network: test, finney, or local")
    args = parser.parse_args()

    print(f"Connecting to Bittensor network: {args.network}...")
    try:
        sub = bt.subtensor(network=args.network)
    except Exception as e:
        sys.exit(f"Error connecting to Subtensor: {e}")

    print(f"Fetching stake info for: {args.ss58_address}")
    print("-" * 60)

    try:
        stakes = sub.get_stake_info_for_coldkey(args.ss58_address)
        if not stakes:
            print("No stake found for this address.")
            return

        total_stake = 0.0
        print(f"{'VALIDATOR HOTKEY (Delegated To)':<50} | {'STAKE (TAO)':>15}")
        print("-" * 60)

        for stake_info in stakes:
            amount = float(stake_info.stake)
            if amount > 0:
                print(f"{stake_info.hotkey_ss58:<50} | {amount:>15.9f}")
                total_stake += amount

        print("-" * 60)
        print(f"{'TOTAL ALPHA / STAKE':<50} | {total_stake:>15.9f} TAO")
        print("-" * 60)

    except Exception as e:
        sys.exit(f"Error fetching stake data: {e}")

if __name__ == "__main__":
    main()