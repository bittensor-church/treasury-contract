#!/usr/bin/env python3
"""
CLI to fetch REAL stake breakdown directly from the Subtensor chain (bypassing EVM/Mock).
"""

import argparse
import sys
import bittensor as bt

def main():
    parser = argparse.ArgumentParser(description="Get Real Stake Breakdown from Subtensor")

    # Tutaj podajemy adres SS58 (np. 5Hg...), bo to na nim żyje Stake w Bittensorze
    parser.add_argument("ss58_address", help="Coldkey SS58 Address (e.g. 5HTBix...)")

    # Wybór sieci (test/finney/local)
    parser.add_argument("--network", default="test", help="Network: test, finney, or local")

    args = parser.parse_args()

    print(f"Connecting to Bittensor network: {args.network}...")

    try:
        # 1. Połączenie z Subtensor
        sub = bt.subtensor(network=args.network)
    except Exception as e:
        print(f"Error connecting to Subtensor: {e}")
        sys.exit(1)

    print(f"Fetching stake info for: {args.ss58_address}")
    print("-" * 60)

    try:
        # 2. Pobranie pełnej listy delegacji dla tego Coldkeya
        # Zwraca listę obiektów StakeInfo
        stakes = sub.get_stake_info_for_coldkey(args.ss58_address)

        if not stakes:
            print("No stake found for this address.")
            return

        total_stake = 0.0

        # Nagłówki tabeli
        print(f"{'VALIDATOR HOTKEY (Delegated To)':<50} | {'STAKE (TAO)':>15}")
        print("-" * 60)

        # 3. Iteracja po walidatorach
        for stake_info in stakes:
            hotkey = stake_info.hotkey_ss58
            amount = float(stake_info.stake)

            # Pomiń zerowe wpisy
            if amount > 0:
                print(f"{hotkey:<50} | {amount:>15.9f}")
                total_stake += amount

        print("-" * 60)
        print(f"{'TOTAL ALPHA / STAKE':<50} | {total_stake:>15.9f} TAO")
        print("-" * 60)

    except Exception as e:
        print(f"Error fetching stake data: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()