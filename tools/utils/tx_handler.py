import sys
from web3 import Web3

def execute_transaction(w3: Web3, account, function_call, value=0, force_gas_price_gwei=None, gas_limit_fallback=500_000):
    """
    Generic wrapper to estimate gas, build, sign, send transaction and wait for receipt.
    """
    print("--- TRANSACTION DETAILS ---")

    # 1. Estimate Gas
    try:
        gas_estimate = function_call.estimate_gas({
            "from": account.address,
            "value": value
        })
        gas_limit = int(gas_estimate * 1.2) # 20% buffer
        print(f"Gas Limit (Estimated): {gas_limit}")
    except Exception as e:
        print(f"Gas estimation warning: {e}. Using fallback {gas_limit_fallback}.", file=sys.stderr)
        gas_limit = gas_limit_fallback

    # 2. Determine Gas Price
    if force_gas_price_gwei:
        gas_price = w3.to_wei(force_gas_price_gwei, 'gwei')
        print(f"Gas Price (FORCED):    {force_gas_price_gwei} Gwei")
    else:
        gas_price = w3.eth.gas_price
        print(f"Gas Price (Node):      {w3.from_wei(gas_price, 'gwei'):.2f} Gwei")

    # 3. Build Transaction
    nonce = w3.eth.get_transaction_count(account.address, "pending")
    tx_build = function_call.build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": gas_limit,
        "gasPrice": gas_price,
        "chainId": w3.eth.chain_id,
        "value": value,
    })

    print(f"Sending transaction (Nonce: {nonce})...")

    # 4. Sign & Send
    try:
        signed = w3.eth.account.sign_transaction(tx_build, private_key=account.key)
        if hasattr(signed, 'rawTransaction'):
            tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
        else:
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)

        print(f"Sent tx: {tx_hash.hex()}")
    except Exception as e:
        print(f"Transaction failed locally: {e}")
        sys.exit(1)

    # 5. Wait for Receipt
    print("Waiting for receipt...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    if receipt["status"] == 1:
        print(f"SUCCESS! Block: {receipt['blockNumber']}, Gas Used: {receipt['gasUsed']}")
        return receipt
    else:
        print("FAILED!")
        # Try to decode revert reason
        try:
            tx_input = w3.eth.get_transaction(tx_hash)["input"]
            revert_data = w3.eth.call(
                {"to": receipt["to"], "from": receipt["from"], "data": tx_input, "value": value},
                block_identifier=receipt["blockNumber"]
            )
            print(f"Revert Reason (Hex): {revert_data.hex()}")
        except Exception:
            pass
        sys.exit(1)