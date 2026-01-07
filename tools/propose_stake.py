#!/usr/bin/env python3
"""
CLI to propose Stake Operations via the Governor.
Supports:
  - remove:   Vault unstakes from a validator (gets TAO back).
  - transfer: Vault moves stake from Validator A to Validator B (transferAlpha).
"""

import argparse
import os
import sys
from pathlib import Path
from web3 import Web3

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def main():
    parser = argparse.ArgumentParser(description="Propose Stake Operations (Governor -> Vault)")
    parser.add_argument("governor_addr", help="TreasuryController (Governor) address")
    parser.add_argument("vault_addr", help="TreasuryVault address (Target)")

    # ZMIANA: Usunięto 'add' z choices
    parser.add_argument("--action", required=True, choices=["remove", "transfer"], help="Action to perform")
    parser.add_argument("--hotkey", required=True, help="Primary Validator Hotkey (Hex). For transfer: Source Validator.")
    parser.add_argument("--to-hotkey", help="Target Validator Hotkey (Required ONLY for 'transfer' action)")
    parser.add_argument("--amount", required=True, type=float, help="Amount in TAO")
    parser.add_argument("--netuid", required=True, type=int, help="Network UID")

    parser.add_argument("--description", required=True, help="Proposal description")
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)
    parser.add_argument("--force-gas-price-gwei", type=float)

    args = parser.parse_args()

    # 1. Setup
    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    if not private_key:
        raise SystemExit("Error: Set PRIVATE_KEY env var or pass --private-key")

    w3 = get_web3_provider(args.rpc_url)
    account = w3.eth.account.from_key(private_key)
    print(f"--- WALLET: {account.address} ---")

    # 2. Prepare Data
    try:
        def clean_hex(h): return bytes.fromhex(h[2:] if h.startswith("0x") else h)

        hotkey_bytes = clean_hex(args.hotkey)
        amount_wei = w3.to_wei(args.amount, 'ether')

        if args.action == "transfer":
            if not args.to_hotkey:
                raise ValueError("--to-hotkey is required for 'transfer' action")
            to_hotkey_bytes = clean_hex(args.to_hotkey)

    except Exception as e:
        sys.exit(f"Input Error: {e}")

    # 3. Load Vault ABI
    try:
        vault_artifact = current_dir.parent / "out" / "TreasuryVault.sol" / "TreasuryVault.json"

        if not vault_artifact.exists():
            print("Artifact not found, using manual ABI for encoding...")
            # Manual ABI without addStake
            vault_contract = w3.eth.contract(address=args.vault_addr, abi=[
                {"name": "removeStake", "type": "function", "inputs": [{"name": "h","type":"bytes32"},{"name": "a","type":"uint256"},{"name": "n","type":"uint256"}]},
                {"name": "transferAlpha", "type": "function", "inputs": [{"name": "f","type":"bytes32"},{"name": "t","type":"bytes32"},{"name": "a","type":"uint256"},{"name": "n","type":"uint256"}]}
            ])
        else:
            vault_contract = load_contract(w3, args.vault_addr, vault_artifact)
    except Exception as e:
        sys.exit(f"Error loading Vault ABI: {e}")

    # 4. Generate Calldata
    print(f"--- PREPARING CALLDATA for '{args.action}' ---")

    # ZMIANA: Usunięto blok 'add'

    if args.action == "remove":
        # removeStake(bytes32 hotkey, uint256 amount, uint256 netuid)
        calldata = vault_contract.encodeABI(fn_name="removeStake", args=[hotkey_bytes, amount_wei, args.netuid])

    elif args.action == "transfer":
        # transferAlpha(bytes32 fromValidator, bytes32 toValidator, uint256 amount, uint256 netuid)
        calldata = vault_contract.encodeABI(fn_name="transferAlpha", args=[hotkey_bytes, to_hotkey_bytes, amount_wei, args.netuid])

    calldata_bytes = bytes.fromhex(calldata[2:])
    print(f"Calldata (Hex): {calldata}")

    # 5. Load Governor
    try:
        gov_artifact = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        governor = load_contract(w3, args.governor_addr, gov_artifact)
    except Exception as e:
        sys.exit(f"Error loading Governor ABI: {e}")

    # 6. Build Proposal
    targets = [Web3.to_checksum_address(args.vault_addr)]
    values = [0]
    calldatas = [calldata_bytes]

    fn = governor.functions.propose(targets, values, calldatas, args.description)

    # 7. Execute Transaction
    print("--- SENDING PROPOSAL ---")
    try:
        gas_estimate = fn.estimate_gas({"from": account.address})
        gas_limit = int(gas_estimate * 1.2)
        gas_price = w3.to_wei(args.force_gas_price_gwei, 'gwei') if args.force_gas_price_gwei else w3.eth.gas_price
    except Exception as e:
        print(f"Gas estimate failed: {e}, using fallback")
        gas_limit = 1_000_000
        gas_price = w3.to_wei(100, 'gwei')

    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx = fn.build_transaction({
        "from": account.address, "nonce": nonce, "gas": gas_limit, "gasPrice": gas_price, "chainId": w3.eth.chain_id, "value": 0
    })

    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"Tx Sent: {tx_hash.hex()}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    if receipt["status"] == 1:
        print(f"SUCCESS! Block: {receipt['blockNumber']}")
        try:
            logs = governor.events.ProposalCreated().process_receipt(receipt)
            if logs:
                pid = logs[0]['args']['proposalId']
                print(f"\n[IMPORTANT] PROPOSAL ID: {pid}")
                print(f"[IMPORTANT] Save this ID and Calldata for Queue/Execute.")
        except:
            pass
    else:
        print("FAILED!")

if __name__ == "__main__":
    main()