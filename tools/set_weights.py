#!/usr/bin/env python3
"""
Set validator weights for a subnet using the bittensor SDK.

Examples
  - By UIDs (explicit):
      python tools/set_weights.py \
        --netuid 12 \
        --wallet-name mywallet --hotkey-name myvali \
        --uids 3,7 \
        --weights 0.7,0.3 \
        --network finney

  - By hotkeys (auto-maps to UIDs via metagraph):
      python tools/set_weights.py \
        --netuid 12 \
        --wallet-name mywallet --hotkey-name myvali \
        --hotkeys 5G...abc,5H...xyz \
        --weights 0.5,0.5 \
        --network finney

Notes
  - The hotkey used must be a registered validator on the subnet.
  - Weights will be normalized unless --no-normalize is passed.
  - Provide either --network or --endpoint. If both are provided, --endpoint is used.
"""
from __future__ import annotations

import argparse
import sys
from typing import List, Tuple

try:
    import bittensor as bt
except Exception as exc:  # pragma: no cover
    raise SystemExit(
        "bittensor is required. Install dependencies from requirements.txt"
    ) from exc


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Set Bittensor subnet weights")
    p.add_argument("--netuid", type=int, required=True, help="Target subnet netuid")
    p.add_argument("--wallet-name", default="default", help="Wallet name (coldkey)")
    p.add_argument("--hotkey-name", default="default", help="Hotkey name used to sign")
    p.add_argument("--network", default=None, help="Network key, e.g. finney, test, local")
    p.add_argument("--endpoint", default=None, help="Explicit chain endpoint URL")

    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument(
        "--uids",
        help="Comma-separated list of UIDs, e.g. 0,1,2",
    )
    target.add_argument(
        "--hotkeys",
        help="Comma-separated list of miner hotkeys (SS58)",
    )

    p.add_argument(
        "--weights",
        required=True,
        help="Comma-separated weights corresponding to UIDs/hotkeys",
    )
    p.add_argument(
        "--no-normalize",
        dest="normalize",
        action="store_false",
        default=True,
        help="Do not normalize weights to sum to 1.0",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Compute and print planned uids/weights without submitting",
    )
    p.add_argument(
        "--wait-finalized/--no-wait-finalized",
        dest="wait_finalized",
        default=True,
        action=argparse.BooleanOptionalAction,
        help="Wait for finalization (default: True)",
    )
    p.add_argument(
        "--verbose",
        action="store_true",
        help="Enable bittensor logging",
    )
    return p.parse_args()


def get_subtensor(network: str | None, endpoint: str | None):
    if endpoint:
        return bt.subtensor(chain_endpoint=endpoint)
    if network:
        return bt.subtensor(network=network)
    # Default to finney if nothing is provided
    return bt.subtensor(network="finney")


def parse_list_of_ints(csv: str) -> List[int]:
    return [int(x.strip()) for x in csv.split(",") if x.strip() != ""]


def parse_list_of_floats(csv: str) -> List[float]:
    return [float(x.strip()) for x in csv.split(",") if x.strip() != ""]


def normalize_weights(weights: List[float]) -> List[float]:
    total = float(sum(weights))
    if total <= 0:
        raise ValueError("Weights must sum to > 0")
    return [w / total for w in weights]


def map_hotkeys_to_uids(sub: bt.subtensor, netuid: int, hotkeys: List[str]) -> List[int]:
    mg = sub.metagraph(netuid=netuid, lite=True)
    hk_to_uid = {hk: uid for uid, hk in zip(mg.uids, mg.hotkeys)}
    missing = [hk for hk in hotkeys if hk not in hk_to_uid]
    if missing:
        raise SystemExit(f"Hotkeys not found in metagraph: {missing}")
    return [hk_to_uid[hk] for hk in hotkeys]


def main() -> None:
    args = parse_args()
    if args.verbose:
        bt.logging.set_debug(True)

    # Connect
    subtensor = get_subtensor(args.network, args.endpoint)

    # Load wallet which will sign the set_weights extrinsic
    wallet = bt.wallet(name=args.wallet_name, hotkey=args.hotkey_name)

    # Resolve UIDs and weights
    weights = parse_list_of_floats(args.weights)
    if args.uids:
        uids = parse_list_of_ints(args.uids)
    else:
        # Map hotkeys -> uids via current metagraph
        hotkeys = [hk.strip() for hk in args.hotkeys.split(",") if hk.strip()]
        uids = map_hotkeys_to_uids(subtensor, args.netuid, hotkeys)

    if len(uids) != len(weights):
        raise SystemExit(
            f"Length mismatch: {len(uids)} uids vs {len(weights)} weights"
        )

    # Normalize unless disabled
    if args.normalize:
        weights = normalize_weights(weights)

    # Sanity checks
    if any(w < 0 for w in weights):
        raise SystemExit("Weights must be non-negative")
    if any(not isinstance(uid, int) or uid < 0 for uid in uids):
        raise SystemExit("UIDs must be non-negative integers")

    print("Planned set_weights:")
    print(f"  netuid: {args.netuid}")
    print(f"  uids: {uids}")
    print(f"  weights: {[round(w, 6) for w in weights]}")

    if args.dry_run:
        print("Dry run; not submitting.")
        return

    # Submit set_weights
    ok, err = subtensor.set_weights(
        wallet=wallet,
        netuid=args.netuid,
        uids=uids,
        weights=weights,
        wait_for_inclusion=True,
        wait_for_finalization=args.wait_finalized,
        version_key=0,
    )

    if not ok:
        print(f"set_weights failed: {err}", file=sys.stderr)
        raise SystemExit(1)

    print("set_weights extrinsic included successfully.")


if __name__ == "__main__":
    main()

