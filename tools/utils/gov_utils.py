from web3 import Web3
from eth_abi import encode
from substrateinterface.utils.ss58 import ss58_decode

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def encode_manual_calldata(w3, func_signature, types, args):
    """Manually encodes calldata to match signatures exactly."""
    selector = w3.keccak(text=func_signature)[:4]
    encoded_args = encode(types, args)
    return (selector + encoded_args).hex()

def build_transfer_alpha_calldata(w3, args, amount_wei):
    """
    Reconstructs the targets, values, and calldatas for transferStake execution only.
    Converts recipient from SS58 to bytes32.
    """
    hotkey = bytes.fromhex(clean_hex(args.hotkey).zfill(64))

    recipient_decoded_hex = ss58_decode(args.recipient)
    recipient_coldkey = bytes.fromhex(clean_hex(recipient_decoded_hex))

    targets = []
    values = []
    calldatas = []

    sig_transfer = "transferStake(bytes32,bytes32,uint256,uint256,uint256)"
    types_transfer = ['bytes32', 'bytes32', 'uint256', 'uint256', 'uint256']
    args_transfer = [recipient_coldkey, hotkey, args.netuid, args.netuid, amount_wei]

    calldata_transfer_hex = encode_manual_calldata(w3, sig_transfer, types_transfer, args_transfer)

    targets.append(args.staking_contract)
    values.append(0)
    calldatas.append(bytes.fromhex(calldata_transfer_hex))

    return targets, values, calldatas