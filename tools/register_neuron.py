#!/usr/bin/env python3
"""
Script to register a neuron on the network using a contract.
"""

import argparse
import sys
from pathlib import Path
import bittensor as bt

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import load_contract
from utils.common import setup_web3_with_account, add_web3_arguments
from utils.tx_handler import execute_transaction

def get_burn_cost_fallback(subtensor, netuid):
    try:
        return subtensor.get_subnet_burn_cost(netuid)
    except Exception:
        pass

    for func in ['Recycle', 'Burn']:
        try:
            query_result = subtensor.substrate.query(
                module='SubtensorModule',
                storage_function=func,
                params=[netuid]
            )
            if query_result is not None and hasattr(query_result, 'value'):
                return bt.Balance.from_rao(query_result.value)
        except Exception:
            pass

    raise RuntimeError(f"Could not find Burn/Recycle cost for NetUID {netuid}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("contract")
    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--hotkey", required=True)
    parser.add_argument("--network", default="test")

    # Add standard web3 args
    add_web3_arguments(parser)

    args = parser.parse_args()

    # 1. Bittensor Connection & Cost
    print(f"--- FETCHING NETWORK DATA ({args.network}) ---")
    try:
        subtensor = bt.subtensor(network=args.network)
        burn_cost_tao = get_burn_cost_fallback(subtensor, args.netuid)
        print(f"Current Burn Cost for NetUID {args.netuid}: {burn_cost_tao.tao} TAO")
    except Exception as e:
        print(f"CRITICAL ERROR fetching burn cost: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        if 'subtensor' in locals() and hasattr(subtensor, "substrate"):
            subtensor.substrate.close()

    # 2. Web3 Setup
    w3, account = setup_web3_with_account(args)

    # 3. Balance Check
    balance_wei = w3.eth.get_balance(account.address)
    burn_amount_wei = w3.to_wei(str(burn_cost_tao.tao), 'ether')

    print(f"\n--- WALLET INFO ---")
    print(f"Address: {account.address}")
    print(f"Balance: {w3.from_wei(balance_wei, 'ether'):.6f} TestTAO")
    print(f"Cost:    {burn_cost_tao.tao} TAO")

    if balance_wei < burn_amount_wei:
        print(f"\n[!] ERROR: Insufficient funds.", file=sys.stderr)
        sys.exit(1)

    if input("\nDo you want to proceed? (y/N): ").strip().lower() != 'y':
        print("Aborted.")
        sys.exit(0)

    # 4. Prepare Contract & Hotkey
    try:
        hotkey_bytes32 = bytes.fromhex(args.hotkey.removeprefix("0x"))
        if len(hotkey_bytes32) != 32:
            raise ValueError("Hotkey must be 32 bytes")

        artifact_path = current_dir.parent / "out" / "TreasuryVault.sol" / "TreasuryVault.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        print(f"Error preparing data: {e}", file=sys.stderr)
        sys.exit(1)

    # 5. Execute
    fn = contract.functions.registerNeuron(args.netuid, hotkey_bytes32)

    # Register neuron requires value transfer (burn)
    execute_transaction(
        w3=w3,
        account=account,
        function_call=fn,
        value=burn_amount_wei,
        force_gas_price_gwei=args.force_gas_price_gwei,
        gas_limit_fallback=3_000_000
    )

if __name__ == "__main__":
    main()