#!/usr/bin/env python3
"""
CLI to propose 'transferAlpha' (Atomic Stake Transfer) via Batch Proposal.
Uses LOW-LEVEL ABI encoding to bypass Web3.py version conflicts.
"""

import argparse
import os
import sys
from pathlib import Path
from web3 import Web3
from eth_abi import encode # <--- NAPRAWA: Bezpośredni import

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
    Manually encodes calldata: Selector (4 bytes) + Encoded Args.
    """
    # 1. Oblicz Selector (pierwsze 4 bajty hasha sha3 z sygnatury)
    selector = w3.keccak(text=func_signature)[:4]

    # 2. Zakoduj argumenty używając eth_abi bezpośrednio
    encoded_args = encode(types, args)

    # 3. Złącz w całość
    return (selector + encoded_args).hex()

def main():
    parser = argparse.ArgumentParser(description="Propose Batch: Move & Transfer Stake")

    parser.add_argument("governor", help="Governor Address")

    # WAŻNE: To musi być adres kontraktu STAKINGU (Mocka lub Prekompilatu), a nie Vaulta!
    # Ponieważ Vault ma wywołać funkcję NA TYM kontrakcie.
    parser.add_argument("staking_contract", help="Staking/Mock Contract Address (Target)")

    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--amount", required=True, type=float)

    parser.add_argument("--from-hotkey", required=True, help="Current Validator")
    parser.add_argument("--to-hotkey", required=True, help="New Validator")
    parser.add_argument("--recipient", required=True, help="User Address (EVM)")

    parser.add_argument("--description", required=True)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)

    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    w3 = get_web3_provider(args.rpc_url)
    account = w3.eth.account.from_key(private_key)

    # --- PRZYGOTOWANIE DANYCH ---
    # IMPORTANT: Staking precompile uses 18 decimals (Wei-style), not 9!
    amount_wei = int(args.amount * 1_000_000_000_000_000_000)

    # Hotkeys to bytes32
    from_hotkey = bytes.fromhex(clean_hex(args.from_hotkey).zfill(64))
    to_hotkey = bytes.fromhex(clean_hex(args.to_hotkey).zfill(64))

    # Recipient logic: EVM Address -> Bytes32 Coldkey
    recipient_addr_clean = clean_hex(args.recipient)
    recipient_coldkey = bytes.fromhex(recipient_addr_clean.zfill(64))

    # --- BUDOWANIE BATCHA (RĘCZNE KODOWANIE) ---
    targets = []
    values = []
    calldatas = []

    print(f"--- BUILDING PROPOSAL BATCH (LOW LEVEL) ---")

    # KROK 1: moveStake (Tylko jeśli walidatorzy są różni)
    if from_hotkey != to_hotkey:
        print(f"[Step 1] Adding moveStake (Redelegate)...")

        sig = "moveStake(bytes32,bytes32,uint256,uint256,uint256)"
        types = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
        args_move = [from_hotkey, to_hotkey, args.netuid, args.netuid, amount_wei]

        calldata_hex = encode_manual_calldata(w3, sig, types, args_move)

        targets.append(args.staking_contract)
        values.append(0)
        calldatas.append(bytes.fromhex(calldata_hex))
    else:
        print(f"[Step 1] Skipping moveStake (Validators are the same).")

    # KROK 2: transferStake (Zawsze)
    print(f"[Step 2] Adding transferStake (Ownership Transfer)...")

    # Sygnatura: transferStake(destination_coldkey, hotkey, origin_net, dest_net, amount)
    sig_transfer = "transferStake(bytes32,bytes32,uint256,uint256,uint256)"
    types_transfer = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
    args_transfer = [recipient_coldkey, to_hotkey, args.netuid, args.netuid, amount_wei]

    calldata_transfer_hex = encode_manual_calldata(w3, sig_transfer, types_transfer, args_transfer)

    targets.append(args.staking_contract)
    values.append(0)
    calldatas.append(bytes.fromhex(calldata_transfer_hex))

    # --- WYSYŁANIE DO GOVERNORA ---
    try:
        gov_artifact = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        governor = load_contract(w3, args.governor, gov_artifact)
    except Exception as e:
        sys.exit(f"Error loading Governor ABI: {e}")

    print(f"\nSubmitting Batch Proposal with {len(targets)} actions...")

    try:
        fn = governor.functions.propose(targets, values, calldatas, args.description)
        gas_est = fn.estimate_gas({'from': account.address})
        gas_limit = int(gas_est * 1.2)
    except Exception as e:
        print(f"Gas warning: {e}. Using fallback.")
        gas_limit = 1000000

    tx = fn.build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": gas_limit,
        "gasPrice": w3.eth.gas_price,
        "chainId": w3.eth.chain_id
    })

    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"Tx Sent: {tx_hash.hex()}")

    print("Waiting for receipt...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if receipt.status == 1:
        print("SUCCESS! Proposal Created.")
        try:
            logs = governor.events.ProposalCreated().process_receipt(receipt)
            print(f"Proposal ID: {logs[0]['args']['proposalId']}")
        except:
            pass
    else:
        print("FAILED.")

if __name__ == "__main__":
    main()