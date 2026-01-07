#!/usr/bin/env python3
import sys
from eth_account import Account

def main():
    # Włączamy obsługę mnemoników (wymagane w nowszych wersjach eth_account)
    Account.enable_unaudited_hdwallet_features()

    # Tutaj wklej mnemonik swojego HOTKEYA (nie coldkeya!)
    mnemonic = "capital aerobic daring barely friend hill guilt crazy salute ride cave abuse"

    try:
        # Generowanie portfela EVM z mnemonika
        acct = Account.from_mnemonic(mnemonic)

        print("-" * 40)
        print(f"MNEMONIC:   {mnemonic}")
        print("-" * 40)
        print(f"EVM Address: {acct.address}")
        print(f"PRIVATE KEY: {acct.key.hex()}")
        print("-" * 40)
        print("Skopiuj ten PRIVATE KEY i ustaw jako zmienną środowiskową.")

    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()