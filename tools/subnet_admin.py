#!/usr/bin/env python3
"""
Subnet admin helpers for local E2E testing:
  - disable-commit-reveal          sudo: admin_freeze_window=0, commit_reveal_weights_enabled=false,
                                   weights_set_rate_limit=0 (all required before a freshly-created
                                   subnet accepts set_weights)
  - enable-voting-power-tracking   sudo: SubtensorModule.enable_voting_power_tracking(netuid).
                                   Without this VotingPower stays 0 and finalize() returns Defeated.
  - set-voting-power-ema-alpha     sudo: SubtensorModule.sudo_set_voting_power_ema_alpha(netuid, alpha).
                                   Default 0.00357e18 gives ~2-week e-folding; bump (e.g. 5e17) on
                                   localnet so voting power accumulates quickly.
  - stake-add                      direct SubtensorModule.add_stake signed by the caller's coldkey seed
                                   (bypasses the MEV-shield path that btcli stake add uses)
  - set-weights                    direct SubtensorModule.set_weights signed by a hotkey seed
                                   (bypasses the bittensor SDK's "too soon to commit" guard)
  - get-uid                        prints the UID of a hotkey on a netuid; empty if not registered

Intended for localnet with dev //Alice as sudo.
"""
from __future__ import annotations

import argparse
import sys

from substrateinterface import SubstrateInterface, Keypair


def _make_keypair(seed_or_uri: str) -> Keypair:
    """Accept a hex seed (0x…), a //Alice-style derivation URI, or a BIP39 mnemonic."""
    s = seed_or_uri.strip()
    if s.startswith("0x"):
        return Keypair.create_from_seed(s)
    return Keypair.create_from_uri(s)


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

    rate = si.query("SubtensorModule", "WeightsSetRateLimit", [netuid]).value
    if rate != 0:
        inner = si.compose_call(
            call_module="AdminUtils",
            call_function="sudo_set_weights_set_rate_limit",
            call_params={"netuid": netuid, "weights_set_rate_limit": 0},
        )
        sudo_call(si, sudo_kp, inner)
        print(f"weights_set_rate_limit[{netuid}]: {rate} -> 0")
    else:
        print(f"weights_set_rate_limit[{netuid}] already 0")


def enable_voting_power_tracking(endpoint: str, netuid: int, sudo_uri: str) -> None:
    si = SubstrateInterface(url=endpoint)
    sudo_kp = Keypair.create_from_uri(sudo_uri)

    current = si.query("SubtensorModule", "VotingPowerTrackingEnabled", [netuid]).value
    if current:
        print(f"VotingPowerTrackingEnabled[{netuid}] already true")
        return

    inner = si.compose_call(
        call_module="SubtensorModule",
        call_function="enable_voting_power_tracking",
        call_params={"netuid": netuid},
    )
    sudo_call(si, sudo_kp, inner)
    print(f"VotingPowerTrackingEnabled[{netuid}]: false -> true")


def set_voting_power_ema_alpha(endpoint: str, netuid: int, alpha: int, sudo_uri: str) -> None:
    si = SubstrateInterface(url=endpoint)
    sudo_kp = Keypair.create_from_uri(sudo_uri)

    current = si.query("SubtensorModule", "VotingPowerEmaAlpha", [netuid]).value
    if current == alpha:
        print(f"VotingPowerEmaAlpha[{netuid}] already {alpha}")
        return

    inner = si.compose_call(
        call_module="SubtensorModule",
        call_function="sudo_set_voting_power_ema_alpha",
        call_params={"netuid": netuid, "alpha": alpha},
    )
    sudo_call(si, sudo_kp, inner)
    print(f"VotingPowerEmaAlpha[{netuid}]: {current} -> {alpha}")


def _tao_to_rao(tao: float) -> int:
    return int(round(tao * 1e9))


def stake_add(endpoint: str, coldkey_uri: str, hotkey_ss58: str, netuid: int, amount_tao: float) -> None:
    si = SubstrateInterface(url=endpoint)
    ck = _make_keypair(coldkey_uri)
    amount_rao = _tao_to_rao(amount_tao)

    call = si.compose_call(
        call_module="SubtensorModule",
        call_function="add_stake",
        call_params={
            "hotkey": hotkey_ss58,
            "netuid": netuid,
            "amount_staked": amount_rao,
        },
    )
    ext = si.create_signed_extrinsic(call=call, keypair=ck)
    receipt = si.submit_extrinsic(ext, wait_for_inclusion=True)
    if not receipt.is_success:
        raise SystemExit(f"add_stake failed: {receipt.error_message}")
    print(f"add_stake ok (coldkey={ck.ss58_address} hotkey={hotkey_ss58} netuid={netuid} rao={amount_rao})")


def set_weights(endpoint: str, hotkey_uri: str, netuid: int, uids: list[int], weights: list[int]) -> None:
    si = SubstrateInterface(url=endpoint)
    hk = _make_keypair(hotkey_uri)
    call = si.compose_call(
        call_module="SubtensorModule",
        call_function="set_weights",
        call_params={
            "netuid": netuid,
            "dests": uids,
            "weights": weights,
            "version_key": 0,
        },
    )
    ext = si.create_signed_extrinsic(call=call, keypair=hk)
    receipt = si.submit_extrinsic(ext, wait_for_inclusion=True)
    if not receipt.is_success:
        raise SystemExit(f"set_weights failed: {receipt.error_message}")
    print(f"set_weights ok (hotkey={hk.ss58_address} netuid={netuid} uids={uids} weights={weights})")


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

    e = sub.add_parser("enable-voting-power-tracking")
    e.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    e.add_argument("--netuid", type=int, required=True)
    e.add_argument("--sudo-uri", default="//Alice")

    a = sub.add_parser("set-voting-power-ema-alpha")
    a.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    a.add_argument("--netuid", type=int, required=True)
    a.add_argument(
        "--alpha",
        type=int,
        required=True,
        help="u64 with 18-decimal precision; 1.0 = 10^18, must be <= 10^18",
    )
    a.add_argument("--sudo-uri", default="//Alice")

    g = sub.add_parser("get-uid")
    g.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    g.add_argument("--netuid", type=int, required=True)
    g.add_argument("--hotkey", required=True, help="bytes32 (0x...) or SS58")

    s = sub.add_parser("stake-add")
    s.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    s.add_argument(
        "--coldkey-uri",
        required=True,
        help="Hex seed (0x...), //Alice-style derivation, or BIP39 mnemonic",
    )
    s.add_argument("--hotkey-ss58", required=True)
    s.add_argument("--netuid", type=int, required=True)
    s.add_argument("--amount", type=float, required=True, help="TAO to stake")

    w = sub.add_parser("set-weights")
    w.add_argument("--endpoint", default="ws://127.0.0.1:9944")
    w.add_argument(
        "--hotkey-uri",
        required=True,
        help="Hex seed (0x...), //Alice-style derivation, or BIP39 mnemonic",
    )
    w.add_argument("--netuid", type=int, required=True)
    w.add_argument("--uids", required=True, help="Comma-separated UIDs")
    w.add_argument("--weights", required=True, help="Comma-separated u16 weights matching --uids")

    args = p.parse_args()

    if args.cmd == "disable-commit-reveal":
        disable_commit_reveal(args.endpoint, args.netuid, args.sudo_uri)
    elif args.cmd == "enable-voting-power-tracking":
        enable_voting_power_tracking(args.endpoint, args.netuid, args.sudo_uri)
    elif args.cmd == "set-voting-power-ema-alpha":
        set_voting_power_ema_alpha(args.endpoint, args.netuid, args.alpha, args.sudo_uri)
    elif args.cmd == "get-uid":
        get_uid(args.endpoint, args.netuid, args.hotkey)
    elif args.cmd == "stake-add":
        stake_add(args.endpoint, args.coldkey_uri, args.hotkey_ss58, args.netuid, args.amount)
    elif args.cmd == "set-weights":
        uids = [int(x) for x in args.uids.split(",") if x.strip()]
        weights = [int(x) for x in args.weights.split(",") if x.strip()]
        if len(uids) != len(weights):
            raise SystemExit("uids and weights length mismatch")
        set_weights(args.endpoint, args.hotkey_uri, args.netuid, uids, weights)


if __name__ == "__main__":
    main()
