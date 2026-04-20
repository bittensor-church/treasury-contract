#!/usr/bin/env python3
"""
CLI to query Proposal State from TreasuryController (Governor).
"""

import argparse
import sys
from pathlib import Path

current_dir = Path(__file__).resolve().parent
if str(current_dir) not in sys.path:
    sys.path.append(str(current_dir))

from utils.contract_loader import load_contract
from utils.common import setup_web3_connection, add_web3_arguments

STATES = [
    "Pending",   # 0
    "Active",    # 1
    "Canceled",  # 2
    "Defeated",  # 3
    "Succeeded", # 4
    "Queued",    # 5
    "Expired",   # 6
    "Executed"   # 7
]

def main():
    parser = argparse.ArgumentParser(description="Get Proposal State")
    parser.add_argument("contract", help="Governor contract address")
    parser.add_argument("--proposal-id", required=True, type=int)

    add_web3_arguments(parser, requires_private_key=False)
    args = parser.parse_args()

    try:
        w3 = setup_web3_connection(args.rpc_url)
    except Exception as e:
        sys.exit(f"RPC Connection Error: {e}")

    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Load Error: {e}")

    print("-" * 40)
    print(f"QUERY PROPOSAL: {args.proposal_id}")
    print("-" * 40)

    try:
        state_enum = contract.functions.state(args.proposal_id).call()
        state_str = STATES[state_enum] if 0 <= state_enum < len(STATES) else "Unknown"
        print(f"State:      {state_str} ({state_enum})")
    except Exception as e:
        print(f"State:      Error ({e})")

    try:
        snapshot = contract.functions.proposalSnapshot(args.proposal_id).call()
        deadline = contract.functions.proposalDeadline(args.proposal_id).call()
        current_block = w3.eth.block_number

        print(f"Snapshot:   Block {snapshot}")
        print(f"Deadline:   Block {deadline}")
        print(f"Current:    Block {current_block}")

        if current_block < deadline:
            print(f"Remaining:  {deadline - current_block} blocks")
        else:
            print(f"Status:     Voting Ended")

    except Exception as e:
        print(f"Details:    Error fetching details ({e})")

    print("-" * 40)

if __name__ == "__main__":
    main()