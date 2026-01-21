#!/usr/bin/env python3
"""
Direct Execution on TreasuryVault (Timelock) bypassing Governor.
Steps: Schedule -> Wait (Hardcoded 5s) -> Execute.
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

try:
    from utils.contract_loader import load_contract
    from utils.common import setup_web3_with_account, add_web3_arguments
    from utils.tx_handler import execute_transaction
except ImportError:
    sys.exit("Error: Could not import utils. Make sure you are in the project root.")

# --- HELPER FUNCTIONS ---

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def encode_manual_calldata(w3, func_signature, types, args):
    selector = w3.keccak(text=func_signature)[:4]
    encoded_args = encode(types, args)
    return (selector + encoded_args).hex()

def build_transfer_payload(w3, args, amount_wei):
    hotkey = bytes.fromhex(clean_hex(args.hotkey).zfill(64))
    recipient_decoded_hex = ss58_decode(args.recipient)
    recipient_coldkey = bytes.fromhex(clean_hex(recipient_decoded_hex))

    sig_transfer = "transferStake(bytes32,bytes32,uint256,uint256,uint256)"
    types_transfer = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
    args_transfer = [recipient_coldkey, hotkey, args.netuid, args.netuid, amount_wei]

    calldata_transfer_hex = encode_manual_calldata(w3, sig_transfer, types_transfer, args_transfer)

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

    # 1. LOAD CONTRACT
    try:
        vault_artifact = current_dir.parent / "out" / "TreasuryVault.sol" / "TreasuryVault.json"

        # Fallback do prostego ABI Timelocka, jeśli plik JSON nie istnieje (dla bezpieczeństwa)
        if not vault_artifact.exists():
            print("Warning: Artifact not found. Using generic Timelock ABI.")
            timelock_abi = [
                {"inputs":[{"internalType":"address[]","name":"targets","type":"address[]"},{"internalType":"uint256[]","name":"values","type":"uint256[]"},{"internalType":"bytes[]","name":"payloads","type":"bytes[]"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256","name":"delay","type":"uint256"}],"name":"scheduleBatch","outputs":[],"stateMutability":"nonpayable","type":"function"},
                {"inputs":[{"internalType":"address[]","name":"targets","type":"address[]"},{"internalType":"uint256[]","name":"values","type":"uint256[]"},{"internalType":"bytes[]","name":"payloads","type":"bytes[]"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"}],"name":"executeBatch","outputs":[],"stateMutability":"payable","type":"function"}
            ]
            vault = w3.eth.contract(address=args.vault, abi=timelock_abi)
        else:
            vault = load_contract(w3, args.vault, vault_artifact)

        print(f"Loaded TreasuryVault at: {args.vault}")

    except Exception as e:
        sys.exit(f"Error loading Contract ABI: {e}")

    # 2. HARDCODED MIN DELAY (Zgodnie z prośbą)
    min_delay = 15
    print(f"Vault Min Delay (Hardcoded): {min_delay} seconds")

    # 3. PREPARE DATA
    targets, values, calldatas = build_transfer_payload(w3, args, amount_wei)

    salt = "0x" + secrets.token_hex(32)
    predecessor = "0x" + "00"*32

    print(f"Generated Salt: {salt}")

    # 4. SCHEDULE
    print("\n[1/3] Scheduling Batch Operation...")

    try:
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
    except Exception as e:
        print("\n!!! ERROR DURING SCHEDULE !!!")
        print(f"Error: {e}")
        print("NOTE: If you get 'Unknown selector' here, your $VAULT address is definitely WRONG.")
        sys.exit(1)

    # 5. WAIT
    print(f"\n[2/3] Waiting {min_delay} seconds for Timelock...")
    for i in range(min_delay + 2, 0, -1):
        sys.stdout.write(f"\rTime remaining: {i}s ")
        sys.stdout.flush()
        time.sleep(1)
    print("\nReady to execute!")

    # 6. EXECUTE
    print("\n[3/3] Executing Batch Operation...")

    try:
        execute_fn = vault.functions.executeBatch(
            targets,
            values,
            calldatas,
            predecessor,
            salt
        )

        receipt_exec = execute_transaction(
            w3=w3,
            account=account,
            function_call=execute_fn,
            force_gas_price_gwei=args.force_gas_price_gwei,
            gas_limit_fallback=5_000_000
        )
        print(f"Execute TX Hash: {receipt_exec.transactionHash.hex()}")
        print("SUCCESS: Operation executed directly on Vault.")

    except Exception as e:
        print(f"EXECUTION FAILED: {e}")
        print(f"To retry manually, save this salt: {salt}")

if __name__ == "__main__":
    main()