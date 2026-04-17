#!/usr/bin/env python3
"""
Subnet admin helpers for local E2E testing:
  - disable-commit-reveal  (sudo-sets admin_freeze_window=0, then sets commit_reveal_weights_enabled=false)
  - get-uid                (prints the UID of a hotkey on a netuid; empty if not registered)

Intended for localnet with dev //Alice as sudo.
"""
from __future__ import annotations

import argparse
import sys

from substrateinterface import SubstrateInterface, Keypair


def sudo_call(si: SubstrateInterface, sudo_keypair: Keypair, inner_call) -> None:
    call = si.compose_call(
        call_module="Sudo",
        call_function="sudo",
        call_params={"call": inner_call},
    )
    extrinsic = si.create_signed_extrinsic(call=call, keypair=sudo_keypair)
    receipt = si.submit_extrinsic(extrinsic, wait_for_inclusion=True)
    if not receipt.is_success:
        raise SystemExit(f"Sudo call failed: {receipt.error_message}")


def disable_commit_reveal(endpoint: str, netuid: int, sudo_uri: str) -> None:
    si = SubstrateInterface(url=endpoint)
    sudo_kp = Keypair.create_from_uri(sudo_uri)

    current_window = si.query("SubtensorModule", "AdminFreezeWindow").value
    if current_window != 0:
        inner = si.compose_call(
            call_module="AdminUtils",
            call_function="sudo_set_admin_freeze_window",
            call_params={"window": 0},
        )
        sudo_call(si, sudo_kp, inner)
        print(f"AdminFreezeWindow: {current_window} -> 0")
    else:
        print("AdminFreezeWindow already 0")

    cr_enabled = si.query(
        "SubtensorModule", "CommitRevealWeightsEnabled", [netuid]
    ).value
    if cr_enabled:
        inner = si.compose_call(
            call_module="AdminUtils",
            call_function="sudo_set_commit_reveal_weights_enabled",
            call_params={"netuid": netuid, "enabled": False},
        )
        sudo_call(si, sudo_kp, inner)
        print(f"commit_reveal_weights_enabled[{netuid}]: true -> false")
    else:
        print(f"commit_reveal_weights_enabled[{netuid}] already false")


def get_uid(endpoint: str, netuid: int, hotkey_b32_or_ss58: str) -> None:
    si = SubstrateInterface(url=endpoint)

    if hotkey_b32_or_ss58.startswith("0x"):
        from substrateinterface.utils.ss58 import ss58_encode

        hotkey_ss58 = ss58_encode(hotkey_b32_or_ss58, ss58_format=42)
    else:
        hotkey_ss58 = hotkey_b32_or_ss58

    uid = si.query("SubtensorModule", "Uids", [netuid, hotkey_ss58])
    if uid.value is None:
        print("", end="")
        sys.exit(1)
    print(uid.value)


def main() -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("disable-commit-reveal")
    d.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    d.add_argument("--netuid", type=int, required=True)
    d.add_argument("--sudo-uri", default="//Alice")

    g = sub.add_parser("get-uid")
    g.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    g.add_argument("--netuid", type=int, required=True)
    g.add_argument("--hotkey", required=True, help="bytes32 (0x...) or SS58")

    args = p.parse_args()

    if args.cmd == "disable-commit-reveal":
        disable_commit_reveal(args.endpoint, args.netuid, args.sudo_uri)
    elif args.cmd == "get-uid":
        get_uid(args.endpoint, args.netuid, args.hotkey)


if __name__ == "__main__":
    main()
