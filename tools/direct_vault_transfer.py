#!/usr/bin/env python3
"""
Direct Execution on TreasuryVault (Timelock) bypassing Governor.
Steps: Schedule -> Wait (minDelay) -> Execute.
"""

import argparse
import sys
import time
import secrets
from pathlib import Path
from web3 import Web3
from eth_abi import encode
from substrateinterface.utils.ss58 import ss58_decode

# --- SETUP PATHS & IMPORTS ---
current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

# Zakładam, że te pliki masz w utils/ tak jak w poprzednim skrypcie
try:
    from utils.contract_loader import load_contract
    from utils.common import setup_web3_with_account, add_web3_arguments
    from utils.tx_handler import execute_transaction
except ImportError:
    print("Błąd importów. Upewnij się, że jesteś w katalogu root projektu i masz folder utils.")
    sys.exit(1)

# --- HELPER FUNCTIONS (Z Twojego kodu) ---

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def encode_manual_calldata(w3, func_signature, types, args):
    selector = w3.keccak(text=func_signature)[:4]
    encoded_args = encode(types, args)
    return (selector + encoded_args).hex()

def build_transfer_payload(w3, args, amount_wei):
    """
    Buduje payload dla transferStake.
    Zwraca targets, values, calldatas (listy).
    """
    # Dekodowanie adresów
    hotkey = bytes.fromhex(clean_hex(args.hotkey).zfill(64))
    recipient_decoded_hex = ss58_decode(args.recipient)
    recipient_coldkey = bytes.fromhex(clean_hex(recipient_decoded_hex))

    # Sygnatura i typy (z Twojego snippetu)
    sig_transfer = "transferStake(bytes32,bytes32,uint256,uint256,uint256)"
    types_transfer = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']

    # Argumenty dla prekompilacji
    args_transfer = [recipient_coldkey, hotkey, args.netuid, args.netuid, amount_wei]

    calldata_transfer_hex = encode_manual_calldata(w3, sig_transfer, types_transfer, args_transfer)

    # Formatowanie pod Batch
    targets = [args.staking_contract]
    values = [0]
    calldatas = [bytes.fromhex(calldata_transfer_hex)]

    return targets, values, calldatas

# --- MAIN SCRIPT ---

def main():
    parser = argparse.ArgumentParser(description="Direct Vault Execution (Schedule & Execute)")

    parser.add_argument("vault", help="TreasuryVault Address")
    parser.add_argument("staking_contract", help="Staking Precompile Address")
    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--amount", required=True, type=float)
    parser.add_argument("--hotkey", required=True, help="HotKey Hex")
    parser.add_argument("--recipient", required=True, help="Recipient SS58")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)
    amount_wei = int(args.amount * 1_000_000_000_000_000_000)

    print(f"--- PREPARING DIRECT VAULT EXECUTION ---")

    # 1. Załaduj kontrakt Vaulta
    # Używamy prostego ABI Timelocka, bo TreasuryVault dziedziczy z TimelockController
    # Możesz tu podać ścieżkę do TreasuryVault.json jeśli wolisz
    timelock_abi = [
        {
            "inputs": [],
            "name": "getMinDelay",
            "outputs": [{"internalType": "uint256","name": "","type": "uint256"}],
            "stateMutability": "view",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "address[]","name": "targets","type": "address[]"},
                {"internalType": "uint256[]","name": "values","type": "uint256[]"},
                {"internalType": "bytes[]","name": "payloads","type": "bytes[]"},
                {"internalType": "bytes32","name": "predecessor","type": "bytes32"},
                {"internalType": "bytes32","name": "salt","type": "bytes32"},
                {"internalType": "uint256","name": "delay","type": "uint256"}
            ],
            "name": "scheduleBatch",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "address[]","name": "targets","type": "address[]"},
                {"internalType": "uint256[]","name": "values","type": "uint256[]"},
                {"internalType": "bytes[]","name": "payloads","type": "bytes[]"},
                {"internalType": "bytes32","name": "predecessor","type": "bytes32"},
                {"internalType": "bytes32","name": "salt","type": "bytes32"}
            ],
            "name": "executeBatch",
            "outputs": [],
            "stateMutability": "payable",
            "type": "function"
        }
    ]

    vault = w3.eth.contract(address=args.vault, abi=timelock_abi)

    # 2. Przygotuj dane (Calldata)
    targets, values, calldatas = build_transfer_payload(w3, args, amount_wei)

    # Generuj losowy SALT (wymagany, aby operacja była unikalna)
    salt = "0x" + secrets.token_hex(32)
    predecessor = "0x" + "00"*32 # Puste (brak zależności od innej transakcji)

    # Pobierz aktualny MinDelay z kontraktu
    min_delay = vault.functions.getMinDelay().call()
    print(f"Vault Min Delay: {min_delay} seconds")
    print(f"Generated Salt: {salt}")

    # 3. KROK 1: SCHEDULE (Zaplanuj)
    print("\n[1/3] Scheduling Batch Operation...")

    schedule_fn = vault.functions.scheduleBatch(
        targets,
        values,
        calldatas,
        predecessor,
        salt,
        min_delay
    )

    receipt = execute_transaction(
        w3=w3,
        account=account,
        function_call=schedule_fn,
        force_gas_price_gwei=args.force_gas_price_gwei
    )
    print(f"Schedule TX Hash: {receipt.transactionHash.hex()}")

    # 4. KROK 2: WAIT (Czekaj)
    if min_delay > 0:
        print(f"\n[2/3] Waiting {min_delay} seconds for Timelock...")
        # Dodajemy mały bufor (+2 sekundy), aby upewnić się, że blok został wykopany
        for i in range(min_delay + 2, 0, -1):
            sys.stdout.write(f"\rTime remaining: {i}s ")
            sys.stdout.flush()
            time.sleep(1)
        print("\nReady to execute!")
    else:
        print("\n[2/3] No delay required.")

    # 5. KROK 3: EXECUTE (Wykonaj)
    print("\n[3/3] Executing Batch Operation...")

    execute_fn = vault.functions.executeBatch(
        targets,
        values,
        calldatas,
        predecessor,
        salt
    )

    # Tutaj może być potrzebny wyższy Gas Limit dla prekompilacji
    try:
        receipt_exec = execute_transaction(
            w3=w3,
            account=account,
            function_call=execute_fn,
            force_gas_price_gwei=args.force_gas_price_gwei,
            gas_limit_fallback=5_000_000 # Fallback na wypadek problemów z estymacją prekompilacji
        )
        print(f"Execute TX Hash: {receipt_exec.transactionHash.hex()}")
        print("SUCCESS: Operation executed directly on Vault.")
    except Exception as e:
        print(f"EXECUTION FAILED: {e}")
        # Jeśli się nie uda, salt i dane są już 'zaplanowane', można spróbować 'execute' ręcznie ponownie
        print(f"You can retry execution manually using salt: {salt}")

if __name__ == "__main__":
    main()