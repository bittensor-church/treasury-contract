#!/usr/bin/env python3
"""
CLI to QUEUE 'transferAlpha' proposal.
It reconstructs the exact same calldata as the propose script to ensure the hash matches.
"""

import argparse
import os
import sys
from pathlib import Path
from web3 import Web3
from eth_abi import encode

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def encode_manual_calldata(w3, func_signature, types, args):
    """
    Manually encodes calldata to ensure exact match with propose script.
    """
    selector = w3.keccak(text=func_signature)[:4]
    encoded_args = encode(types, args)
    return (selector + encoded_args).hex()

def main():
    parser = argparse.ArgumentParser(description="Queue Transfer Alpha Proposal")

    # Arguments matching propose script
    parser.add_argument("governor", help="Governor Address")
    parser.add_argument("staking_contract", help="Staking/Mock Contract Address (Target)")

    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--amount", required=True, type=float)

    parser.add_argument("--from-hotkey", required=True, help="Current Validator")
    parser.add_argument("--to-hotkey", required=True, help="New Validator")
    parser.add_argument("--recipient", required=True, help="User Address (EVM)")

    parser.add_argument("--description", required=True, help="Must match proposal description EXACTLY")

    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)

    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    if not private_key:
        sys.exit("Error: Set PRIVATE_KEY env var or pass --private-key")

    try:
        w3 = get_web3_provider(args.rpc_url)
        account = w3.eth.account.from_key(private_key)
        print(f"--- WALLET: {account.address} ---")
    except Exception as e:
        sys.exit(f"Web3 Error: {e}")

    # --- RECONSTRUCT DATA (EXACTLY AS IN PROPOSE SCRIPT) ---
    # IMPORTANT: Staking precompile uses 18 decimals (Wei-style), not 9!
    amount_wei = int(args.amount * 1_000_000_000_000_000_000)

    from_hotkey = bytes.fromhex(clean_hex(args.from_hotkey).zfill(64))
    to_hotkey = bytes.fromhex(clean_hex(args.to_hotkey).zfill(64))

    recipient_addr_clean = clean_hex(args.recipient)
    recipient_coldkey = bytes.fromhex(recipient_addr_clean.zfill(64))

    targets = []
    values = []
    calldatas = []

    print(f"--- RECONSTRUCTING CALLDATA ---")

    # Step 1: moveStake logic
    if from_hotkey != to_hotkey:
        print(f"[Step 1] Adding moveStake...")
        sig = "moveStake(bytes32,bytes32,uint256,uint256,uint256)"
        types = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
        args_move = [from_hotkey, to_hotkey, args.netuid, args.netuid, amount_wei]

        calldata_hex = encode_manual_calldata(w3, sig, types, args_move)

        targets.append(args.staking_contract)
        values.append(0)
        calldatas.append(bytes.fromhex(calldata_hex))
    else:
        print(f"[Step 1] Skipping moveStake (Validators match).")

    # Step 2: transferStake logic
    print(f"[Step 2] Adding transferStake...")
    sig_transfer = "transferStake(bytes32,bytes32,uint256,uint256,uint256)"
    types_transfer = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
    args_transfer = [recipient_coldkey, to_hotkey, args.netuid, args.netuid, amount_wei]

    calldata_transfer_hex = encode_manual_calldata(w3, sig_transfer, types_transfer, args_transfer)

    targets.append(args.staking_contract)
    values.append(0)
    calldatas.append(bytes.fromhex(calldata_transfer_hex))

    # Calculate Description Hash
    description_hash = Web3.keccak(text=args.description)

    print(f"\nQueueing Proposal with {len(targets)} actions...")
    print(f"Description Hash: {description_hash.hex()}")

    # --- LOAD GOVERNOR ---
    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.governor, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Load Error: {e}")

    # --- SEND QUEUE TX ---
    fn = contract.functions.queue(targets, values, calldatas, description_hash)

    try:
        gas_est = fn.estimate_gas({'from': account.address})
        gas_limit = int(gas_est * 1.2)
        print(f"Gas Estimate: {gas_est}")
    except Exception as e:
        print(f"Gas warning: {e}. Using fallback.")
        gas_limit = 500_000

    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx = fn.build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": gas_limit,
        "gasPrice": w3.eth.gas_price,
        "chainId": w3.eth.chain_id,
        "value": 0
    })

    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"Sent tx: {tx_hash.hex()}")

    print("Waiting for receipt...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    if receipt["status"] == 1:
        print(f"SUCCESS! Proposal Queued. Block: {receipt['blockNumber']}")
    else:
        print("FAILED! Transaction reverted.")

if __name__ == "__main__":
    main()