#!/usr/bin/env python3

import argparse
import os
import sys
from pathlib import Path
import bittensor as bt

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import get_web3_provider, load_contract


def get_burn_cost_fallback(subtensor, netuid):
    try:
        return subtensor.get_subnet_burn_cost(netuid)
    except Exception:
        pass

    try:
        query_result = subtensor.substrate.query(
            module='SubtensorModule',
            storage_function='Recycle',
            params=[netuid]
        )
        if query_result is not None and hasattr(query_result, 'value'):
            return bt.Balance.from_rao(query_result.value)
    except Exception:
        pass

    try:
        query_result = subtensor.substrate.query(
            module='SubtensorModule',
            storage_function='Burn',
            params=[netuid]
        )
        if query_result is not None and hasattr(query_result, 'value'):
            return bt.Balance.from_rao(query_result.value)
    except Exception:
        pass

    raise RuntimeError(f"Could not find Burn/Recycle cost for NetUID {netuid} in storage")


def safe_cleanup(subtensor=None, w3=None):
    """Force close Substrate and Web3 sessions to avoid hanging threads."""
    try:
        if subtensor and hasattr(subtensor, "substrate"):
            subtensor.substrate.close()
    except Exception:
        pass

    try:
        if w3 and hasattr(w3.provider, "session"):
            w3.provider.session.close()
    except Exception:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("contract")
    parser.add_argument("--netuid", required=True, type=int)
    parser.add_argument("--hotkey", required=True)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--private-key", default=None)
    parser.add_argument("--network", default="test")
    parser.add_argument("--force-gas-price-gwei", type=float)
    args = parser.parse_args()

    private_key = args.private_key or os.getenv("PRIVATE_KEY")
    if not private_key:
        raise SystemExit("Error: Set PRIVATE_KEY env var or pass --private-key")

    print(f"--- FETCHING NETWORK DATA ({args.network}) ---")
    try:
        subtensor = bt.subtensor(network=args.network)
        burn_cost_tao = get_burn_cost_fallback(subtensor, args.netuid)

        print(f"Current Burn Cost for NetUID {args.netuid}: {burn_cost_tao.tao} TAO")

    except Exception as e:
        print(f"CRITICAL ERROR fetching burn cost: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        w3 = get_web3_provider(args.rpc_url)
        account = w3.eth.account.from_key(private_key)
        balance_wei = w3.eth.get_balance(account.address)
        balance_eth = w3.from_wei(balance_wei, 'ether')

        print(f"\n--- WALLET INFO ---")
        print(f"Address: {account.address}")
        print(f"Balance: {balance_eth:.6f} TestTAO")

        if balance_wei == 0:
            print("\n[!] CRITICAL ERROR: Your wallet has 0 Balance.", file=sys.stderr)
            safe_cleanup(subtensor, w3)
            sys.exit(1)

    except Exception as e:
        print(f"CRITICAL ERROR connecting to Web3: {e}", file=sys.stderr)
        safe_cleanup(subtensor)
        sys.exit(1)

    burn_amount_wei = w3.to_wei(str(burn_cost_tao.tao), 'ether')

    print(f"\n--- CONFIRMATION ---")
    print(f"Operation: Register Neuron on NetUID {args.netuid}")
    print(f"Contract:  {args.contract}")
    print(f"Hotkey:    {args.hotkey}")
    print(f"Cost:      {burn_cost_tao.tao} TAO")

    if balance_wei < burn_amount_wei:
        print(f"\n[!] ERROR: Insufficient funds.")
        print(f"Have: {balance_eth}")
        print(f"Need: {burn_cost_tao.tao}")
        safe_cleanup(subtensor, w3)
        sys.exit(1)

    confirm = input("\nDo you want to proceed? (y/N): ").strip().lower()
    if confirm != 'y':
        print("Aborted by user.")
        safe_cleanup(subtensor, w3)
        sys.exit(0)

    try:
        if args.hotkey.startswith("0x"):
            hotkey_bytes32 = bytes.fromhex(args.hotkey[2:])
        else:
            hotkey_bytes32 = bytes.fromhex(args.hotkey)

        if len(hotkey_bytes32) != 32:
            raise ValueError(f"Hotkey must be 32 bytes, got {len(hotkey_bytes32)}")

    except ValueError as e:
        print(f"CRITICAL ERROR: Invalid input data: {e}", file=sys.stderr)
        safe_cleanup(subtensor, w3)
        sys.exit(1)

    try:
        artifact_path = current_dir.parent / "out" / "TreasuryVault.sol" / "TreasuryVault.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        print(f"CRITICAL ERROR loading contract: {e}", file=sys.stderr)
        safe_cleanup(subtensor, w3)
        sys.exit(1)

    fn = contract.functions.registerNeuron(args.netuid, hotkey_bytes32)

    print("\n--- ESTIMATING GAS ---")
    try:
        gas_estimate = fn.estimate_gas({
            "from": account.address,
            "value": burn_amount_wei
        })
        gas_limit = int(gas_estimate * 2.0)
        print(f"Gas Limit (Estimated): {gas_limit}")

        if args.force_gas_price_gwei:
            gas_price = w3.to_wei(args.force_gas_price_gwei, 'gwei')
        else:
            gas_price = w3.eth.gas_price

        gas_cost_wei = gas_limit * gas_price
        total_cost_eth = w3.from_wei(gas_cost_wei + burn_amount_wei, 'ether')

        print(f"Total Max Cost: {total_cost_eth:.6f} TAO")

    except Exception as exc:
        print(f"Gas estimation warning: {exc}. Using fallback.", file=sys.stderr)
        gas_limit = 3_000_000
        gas_price = w3.to_wei(100, 'gwei')

    nonce = w3.eth.get_transaction_count(account.address, "pending")

    tx = fn.build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": gas_limit,
        "gasPrice": gas_price,
        "chainId": w3.eth.chain_id,
        "value": burn_amount_wei,
    })

    print(f"Sending transaction (Nonce: {nonce})...")
    signed = w3.eth.account.sign_transaction(tx, private_key=private_key)

    try:
        if hasattr(signed, 'rawTransaction'):
            tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
        else:
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)

        print(f"Sent tx: {tx_hash.hex()}")
    except Exception as e:
        print(f"Transaction failed locally: {e}")
        safe_cleanup(subtensor, w3)
        sys.exit(1)

    print("Waiting for receipt...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    if receipt["status"] == 1:
        print(f"SUCCESS! Block: {receipt['blockNumber']}, Gas Used: {receipt['gasUsed']}")
    else:
        print("FAILED!")
        try:
            tx_input = w3.eth.get_transaction(tx_hash)["input"]
            revert_data = w3.eth.call(
                {"to": receipt["to"], "from": receipt["from"], "data": tx_input, "value": burn_amount_wei},
                block_identifier=receipt["blockNumber"]
            )
            print(f"Revert Reason (Hex): {revert_data.hex()}")
        except Exception as e:
            print(f"Could not decode revert: {e}")

    safe_cleanup(subtensor, w3)
    sys.exit(0)

if __name__ == "__main__":
    main()