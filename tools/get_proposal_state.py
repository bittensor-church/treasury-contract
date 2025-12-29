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

from utils.contract_loader import get_web3_provider, load_contract

# OpenZeppelin ProposalState Enum
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
    parser.add_argument("--rpc-url", required=True)
    args = parser.parse_args()

    # 1. Connect
    try:
        w3 = get_web3_provider(args.rpc_url)
    except Exception as e:
        sys.exit(f"RPC Connection Error: {e}")

    # 2. Load Contract
    try:
        artifact_path = current_dir.parent / "out" / "TreasuryController.sol" / "TreasuryController.json"
        contract = load_contract(w3, args.contract, artifact_path)
    except Exception as e:
        sys.exit(f"Contract Load Error: {e}")

    print("-" * 40)
    print(f"QUERY PROPOSAL: {args.proposal_id}")
    print("-" * 40)

    # 3. Get State
    try:
        state_enum = contract.functions.state(args.proposal_id).call()
        state_str = STATES[state_enum] if 0 <= state_enum < len(STATES) else "Unknown"
        print(f"State:      {state_str} ({state_enum})")
    except Exception as e:
        print(f"State:      Error ({e})")

    # 4. Get Deadlines (Snapshot & Deadline)
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

    # 5. Get Votes (For/Against/Abstain)
    try:
        # proposalVotes(uint256) returns (against, for, abstain)
        votes = contract.functions.proposalVotes(args.proposal_id).call()

        # Helper to format wei to human readable
        # Assuming token is 9 decimals (Mock) or 18. Just showing raw for safety.
        print("-" * 40)
        print(f"Against:    {votes[0]}")
        print(f"For:        {votes[1]}")
        print(f"Abstain:    {votes[2]}")
    except Exception:
        # Not all governors implement proposalVotes directly depending on extensions,
        # but ours (GovernorCountingSimple) does.
        pass

    print("-" * 40)

if __name__ == "__main__":
    main()