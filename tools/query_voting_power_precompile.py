#!/usr/bin/env python3
"""
Query voting power for an EVM address using the VotingPower precompile.

Flow: EVM Address → UID Lookup → Hotkey → Voting Power

Usage:
    python query_voting_power_precompile.py \
        --rpc-url http://localhost:9944 \
        --evm-address 0x... \
        --netuid 2
"""

import argparse
import subprocess
import sys


def call_precompile(rpc_url: str, to: str, calldata: str) -> str:
    """Call a precompile using cast."""
    cmd = [
        "cast", "call", to, calldata,
        "--rpc-url", rpc_url
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description="Query voting power for EVM address via precompiles")
    parser.add_argument("--rpc-url", default="http://localhost:9944", help="RPC URL")
    parser.add_argument("--evm-address", required=True, help="EVM address to query")
    parser.add_argument("--netuid", type=int, default=2, help="Subnet ID")
    args = parser.parse_args()

    UID_LOOKUP = "0x0000000000000000000000000000000000000806"
    METAGRAPH = "0x0000000000000000000000000000000000000802"
    VOTING_POWER = "0x000000000000000000000000000000000000080D"
    
    print(f"{'='*60}")
    print(f"QUERY VOTING POWER BY EVM ADDRESS")
    print(f"{'='*60}")
    print(f"EVM Address: {args.evm_address}")
    print(f"NetUID: {args.netuid}")
    print(f"{'='*60}")
    
    # Step 1: uidLookup(netuid, evmAddress, limit)
    netuid_hex = hex(args.netuid)[2:].zfill(4)
    evm_padded = args.evm_address.lower().replace("0x", "").zfill(40)
    limit_hex = "0001"
    
    # uidLookup(uint16,address,uint16) = 0x7bbbe0c6
    calldata_uid = f"0x7bbbe0c6{netuid_hex.zfill(64)}{evm_padded.zfill(64)}{limit_hex.zfill(64)}"
    
    print(f"\n1. UID Lookup...")
    result = call_precompile(args.rpc_url, UID_LOOKUP, calldata_uid)
    if not result:
        print("   ❌ No UID found for this EVM address")
        sys.exit(1)
    
    # Parse UID from result (assuming simple response)
    uid = int(result[-4:], 16) if len(result) >= 4 else 0
    print(f"   UID: {uid}")
    
    # Step 2: getHotkey(netuid, uid)
    uid_hex = hex(uid)[2:].zfill(4)
    # getHotkey(uint16,uint16) = selector varies
    calldata_hotkey = f"0xc9d32e50{netuid_hex.zfill(64)}{uid_hex.zfill(64)}"
    
    print(f"\n2. Get Hotkey...")
    hotkey_result = call_precompile(args.rpc_url, METAGRAPH, calldata_hotkey)
    if hotkey_result:
        hotkey = hotkey_result
        print(f"   Hotkey: {hotkey[:20]}...")
    else:
        print("   ❌ Failed to get hotkey")
        sys.exit(1)
    
    # Step 3: getVotingPower(netuid, hotkey)
    hotkey_clean = hotkey.replace("0x", "")
    # getVotingPower(uint16,bytes32) = 0x13bde52a
    calldata_vp = f"0x13bde52a{netuid_hex.zfill(64)}{hotkey_clean}"
    
    print(f"\n3. Get Voting Power...")
    vp_result = call_precompile(args.rpc_url, VOTING_POWER, calldata_vp)
    if vp_result:
        voting_power = int(vp_result, 16)
        voting_power_tao = voting_power / 1_000_000_000
        print(f"   Voting Power (RAO): {voting_power}")
        print(f"   Voting Power (TAO): {voting_power_tao:.9f}")
    else:
        print("   ❌ Failed to get voting power")
    
    print(f"\n{'='*60}")
    print(f"RESULT: {voting_power_tao:.9f} TAO voting power")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
