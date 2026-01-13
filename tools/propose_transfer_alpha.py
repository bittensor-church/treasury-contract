#!/usr/bin/env python3
"""
CLI to propose a 'transferAlpha' operation (Atomic Redelegation).
This creates a proposal in the Governor to execute transferAlpha on the TreasuryVault.
"""

import argparse
import os
import sys
from pathlib import Path
from web3 import Web3

# Setup paths
current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract

def clean_hex(hex_str):
    """Removes 0x prefix if present."""
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def main():
    parser = argparse.ArgumentParser(description="Propose Validator Redelegation (transferAlpha)")

    # Contract Addresses
    parser.add_argument("governor", help="TreasuryController Address (Governor)")
    parser.add_argument("vault", help="TreasuryVault Address (Target of the call)")

    # Logic Parameters
    parser.add_argument("--netuid", required=True, type=int, help="Bittensor Subnet ID")
    parser.add_argument("--amount", required=True, type=float, help="Amount of Stake in TAO")

    # Validators
    parser.add_argument("--from-hotkey", required=True, help="Current Validator Hotkey (Unstake from)")
    parser.add_argument("--to-hotkey", required=True, help="New Validator Hotkey (Stake to)")

    # Proposal Meta
    parser.add_argument("--description", required=True, help="Reason for redelegation")

    # Connection
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)

    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    if not private_key:
        sys.exit("Error: Set PRIVATE_KEY env var or pass --private-key")

    w3 = get_web3_provider(args.rpc_url)
    account = w3.eth.account.from_key(private_key)

    print(f"--- PROPOSING ALPHA TRANSFER (REDELEGATION) ---")
    print(f"Proposer: {account.address}")

    # 1. Load Vault ABI to encode the specific function call
    try:
        vault_artifact = current_dir.parent / "out" / "TreasuryVault.sol" / "TreasuryVault.json"
        vault_contract = load_contract(w3, args.vault, vault_artifact)
    except Exception as e:
        sys.exit(f"Error loading TreasuryVault ABI: {e}")

    # 2. Prepare Data (Conversion to RAO and Bytes32)
    # Bittensor uses 9 decimals (RAO) for staking logic
    amount_rao = int(args.amount * 1_000_000_000)

    try:
        from_bytes = bytes.fromhex(clean_hex(args.from_hotkey).zfill(64))
        to_bytes = bytes.fromhex(clean_hex(args.to_hotkey).zfill(64))
    except ValueError:
        sys.exit("Error: Hotkeys must be valid hex strings.")

    # 3. Encode Calldata for transferAlpha
    # function transferAlpha(bytes32 fromValidator, bytes32 toValidator, uint256 amount, uint256 netuid)
    print(f"\n[1/3] Encoding Calldata for TreasuryVault...")
    calldata = vault_contract.encodeABI(
        fn_name="transferAlpha",
        args=[from_bytes, to_bytes, amount_rao, args.netuid]
    )

    print(f"   Function: transferAlpha")
    print(f"   From:     0x{from_bytes.hex()}")
    print(f"   To:       0x{to_bytes.hex()}")
    print(f"   Amount:   {args.amount} TAO ({amount_rao} RAO)")
    print(f"   NetUID:   {args.netuid}")
    print(f"   Calldata: {calldata}")
    print(f"   (SAVE THIS CALLDATA! You will need it for queue/execute)")

    # 4. Load Governor to submit the proposal
    try:
        gov_artifact = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        governor = load_contract(w3, args.governor, gov_artifact)
    except Exception as e:
        sys.exit(f"Error loading TreasuryController ABI: {e}")

    # 5. Build Proposal Transaction
    # propose(address[] targets, uint256[] values, bytes[] calldatas, string description)
    targets = [args.vault]  # The contract to call is the Vault
    values = [0]            # We are not sending TAO *value*, just calling a function
    calldatas = [bytes.fromhex(clean_hex(calldata))]

    print(f"\n[2/3] Submitting Proposal to Governor...")

    # Estimate Gas
    try:
        fn = governor.functions.propose(targets, values, calldatas, args.description)
        gas_est = fn.estimate_gas({'from': account.address})
        gas_limit = int(gas_est * 1.2)
    except Exception as e:
        print(f"Gas estimation warning: {e}. Using fallback.")
        gas_limit = 500_000

    tx = fn.build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": gas_limit,
        "gasPrice": w3.eth.gas_price,
        "chainId": w3.eth.chain_id
    })

    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"   Tx Sent: {tx_hash.hex()}")

    print("\n[3/3] Waiting for receipt...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    if receipt.status == 1:
        print("SUCCESS! Proposal Created.")
        try:
            # Parse Proposal ID from logs
            logs = governor.events.ProposalCreated().process_receipt(receipt)
            if logs:
                pid = logs[0]['args']['proposalId']
                print(f"\n==> PROPOSAL ID: {pid}")
                print(f"==> Use this ID to vote.")
        except:
            print("Could not parse Proposal ID from logs.")
    else:
        print("FAILED. Transaction reverted.")

if __name__ == "__main__":
    main()