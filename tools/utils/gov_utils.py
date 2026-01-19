from web3 import Web3
from eth_abi import encode

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
    Reconstructs the targets, values, and calldatas for transferAlpha proposal/execution.
    Used by both queue_proposal.py and execute.py to ensure hash consistency.
    """
    from_hotkey = bytes.fromhex(clean_hex(args.from_hotkey).zfill(64))
    to_hotkey = bytes.fromhex(clean_hex(args.to_hotkey).zfill(64))
    recipient_coldkey = bytes.fromhex(clean_hex(args.recipient).zfill(64))

    targets = []
    values = []
    calldatas = []

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

    return targets, values, calldatas