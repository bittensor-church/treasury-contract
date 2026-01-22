#!/usr/bin/env python3
"""
Direct Vault Execution: Transfer Stake.
Calls 'transferStake' on the Staking Precompile via the Vault.
Transfers staked TAO from the Vault to another coldkey.
"""

import argparse
import sys
import time
import secrets
import hashlib
from pathlib import Path
from web3 import Web3
from eth_abi import encode

# --- SETUP PATHS & IMPORTS ---
current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

try:
    from utils.contract_loader import load_contract
    from utils.common import setup_web3_with_account, add_web3_arguments
    from utils.tx_handler import execute_transaction
except ImportError:
    sys.exit("Error: Could not import utils.")

# --- HELPER FUNCTIONS ---

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def get_hashed_id(evm_address):
    """Frontier HashedAddressMapping (evm:address)"""
    prefix = b"evm:"
    addr_bytes = bytes.fromhex(clean_hex(evm_address))
    m = hashlib.blake2b(digest_size=32)
    m.update(prefix + addr_bytes)
    return m.digest()

def get_unified_id(evm_address):
    """Unified mapping: [0]*12 + EVM_ADDRESS"""
    addr_bytes = bytes.fromhex(clean_hex(evm_address))
    return b"\x00"*12 + addr_bytes

def encode_manual_calldata(w3, func_signature, types, args):
    selector = w3.keccak(text=func_signature)[:4]
    encoded_args = encode(types, args)
    return (selector + encoded_args).hex()

def build_payload(w3, args):
    hotkey = bytes.fromhex(clean_hex(args.hotkey).zfill(64))
    
    # Recipient Mapping
    recipient_raw = args.recipient
    if len(clean_hex(recipient_raw)) == 40:
        # It's an EVM address
        if args.mapping == "unified":
            recipient_bytes = get_unified_id(recipient_raw)
            mapping_name = "Unified"
        else:
            recipient_bytes = get_hashed_id(recipient_raw)
            mapping_name = "Hashed (evm:)"
        print(f"Recipient: {recipient_raw} -> {mapping_name} mapping: 0x{recipient_bytes.hex()}")
    else:
        # Assume it's already a 32-byte hex (hotkey or public key)
        recipient_bytes = bytes.fromhex(clean_hex(recipient_raw).zfill(64))
        print(f"Recipient: 0x{recipient_bytes.hex()}")

    # Amounts
    amount_tao = args.amount
    amount_rao = int(amount_tao * 1_000_000_000)      # 1e9 for Precompile
    
    targets = []
    values = []
    calldatas = []

    # 1. TRANSFER STAKE
    # Signature: transferStake(bytes32 destination_coldkey, bytes32 hotkey, uint256 origin_netuid, uint256 destination_netuid, uint256 amount)
    sig_transfer = "transferStake(bytes32,bytes32,uint256,uint256,uint256)"
    types_transfer = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
    args_transfer = [recipient_bytes, hotkey, args.origin_netuid, args.destination_netuid, amount_rao]
    
    calldata_transfer = encode_manual_calldata(w3, sig_transfer, types_transfer, args_transfer)
    
    targets.append(args.staking_contract)
    values.append(0)
    calldatas.append(bytes.fromhex(calldata_transfer))
    
    print(f"Action: Transfer {amount_tao} ALPHA ({amount_rao} RAO) from Netuid {args.origin_netuid} to Netuid {args.destination_netuid} on recipient")

    return targets, values, calldatas

# --- MAIN SCRIPT ---

def main():
    parser = argparse.ArgumentParser(description="Direct Vault: Transfer Stake")

    parser.add_argument("vault", help="TreasuryVault Address")
    parser.add_argument("staking_contract", help="Staking Precompile Address")
    parser.add_argument("--hotkey", required=True, help="HotKey Hex")
    parser.add_argument("--recipient", required=True, help="Recipient Coldkey Hex or EVM Address")
    parser.add_argument("--origin-netuid", required=True, type=int, help="Source Subnet ID")
    parser.add_argument("--destination-netuid", required=True, type=int, help="Destination Subnet ID")
    parser.add_argument("--amount", required=True, type=float, help="Amount in TAO")
    parser.add_argument("--mapping", choices=["hashed", "unified"], default="hashed", help="Mapping type for EVM address (default: hashed)")

    add_web3_arguments(parser)
    args = parser.parse_args()

    w3, account = setup_web3_with_account(args)

    print(f"--- PREPARING STAKE TRANSFER ---")

    # 1. LOAD VAULT
    try:
        vault_artifact = current_dir.parent / "out" / "TreasuryVault.sol" / "TreasuryVault.json"
        
        # Fallback to generic Timelock ABI
        timelock_abi = [
            {"inputs":[{"internalType":"address[]","name":"targets","type":"address[]"},{"internalType":"uint256[]","name":"values","type":"uint256[]"},{"internalType":"bytes[]","name":"payloads","type":"bytes[]"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"},{"internalType":"uint256","name":"delay","type":"uint256"}],"name":"scheduleBatch","outputs":[],"stateMutability":"nonpayable","type":"function"},
            {"inputs":[{"internalType":"address[]","name":"targets","type":"address[]"},{"internalType":"uint256[]","name":"values","type":"uint256[]"},{"internalType":"bytes[]","name":"payloads","type":"bytes[]"},{"internalType":"bytes32","name":"predecessor","type":"bytes32"},{"internalType":"bytes32","name":"salt","type":"bytes32"}],"name":"executeBatch","outputs":[],"stateMutability":"payable","type":"function"}
        ]
        
        if not vault_artifact.exists():
             vault = w3.eth.contract(address=args.vault, abi=timelock_abi)
        else:
             vault = load_contract(w3, args.vault, vault_artifact)
    except Exception as e:
        sys.exit(f"Error loading Contract ABI: {e}")

    # 2. CONFIG
    contract_min_delay = 1
    
    # 3. PREPARE DATA
    targets, values, calldatas = build_payload(w3, args)

    salt = "0x" + secrets.token_hex(32)
    predecessor = "0x" + "00"*32

    # 4. SCHEDULE
    print("\n[1/3] Scheduling Batch Operation...")
    try:
        schedule_fn = vault.functions.scheduleBatch(
            targets,
            values,
            calldatas,
            predecessor,
            salt,
            contract_min_delay 
        )
        receipt = execute_transaction(w3, account, schedule_fn, force_gas_price_gwei=args.force_gas_price_gwei)
        print(f"Schedule TX Hash: {receipt.transactionHash.hex()}")
    except Exception as e:
        print(f"Schedule Failed: {e}")
        sys.exit(1)

    # 5. WAIT
    wait_buffer_seconds = 25
    total_wait_time = contract_min_delay + wait_buffer_seconds
    print(f"\n[2/3] Waiting {total_wait_time} seconds...")
    for i in range(total_wait_time, 0, -1):
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
        receipt_exec = execute_transaction(w3, account, execute_fn, force_gas_price_gwei=args.force_gas_price_gwei, gas_limit_fallback=5_000_000)
        print(f"Execute TX Hash: {receipt_exec.transactionHash.hex()}")
        print("SUCCESS: Stake transfer executed.")
    except Exception as e:
        print(f"EXECUTION FAILED: {e}")
        print(f"Salt: {salt}")

if __name__ == "__main__":
    main()
