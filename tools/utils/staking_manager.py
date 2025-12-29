import json
import subprocess
import sys
# Relative import is crucial here when running as a package
from .address_converter import ss58_to_bytes

def fetch_validator_stakes(coldkey_ss58: str, netuid: int, network: str = "test"):
    """
    Fetches stake info via btcli for a given coldkey, network, and netuid.

    Args:
        coldkey_ss58: The SS58 address of the coldkey.
        netuid: The subnet ID to filter stakes by.
        network: The bittensor network name (e.g., 'test', 'finney', 'local').

    Returns:
        Tuple containing two lists: (list_of_bytes32_hotkeys, list_of_amounts_in_rao)
    """
    print(f"Fetching stake data via btcli...")
    print(f"  > Coldkey: {coldkey_ss58}")
    print(f"  > Network: {network}")
    print(f"  > NetUID:  {netuid}")

    cmd = [
        "btcli", "stake", "list",
        "--network", network,
        "--ss58", coldkey_ss58,
        "--json-out"
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        raise RuntimeError("Error: 'btcli' command not found. Please ensure Bittensor is installed.")

    raw_output = result.stdout.strip()

    # Check for empty output or standard error cases
    if result.returncode != 0:
        err_msg = result.stderr.strip()
        if "No stake found" in raw_output or "No stake found" in err_msg:
            print("Info: No stake found (btcli returned empty).")
            return [], []
        raise RuntimeError(f"Error executing btcli: {err_msg}")

    if not raw_output:
        print("Info: No stake data returned.")
        return [], []

    # JSON SANITIZATION
    # btcli often prints logs (e.g. "Update available") before the actual JSON.
    # We find the first '{' and the last '}' to extract the JSON payload.
    try:
        start_idx = raw_output.find('{')
        end_idx = raw_output.rfind('}') + 1

        if start_idx == -1 or end_idx == 0:
            raise ValueError("No JSON object found in output")

        json_str = raw_output[start_idx:end_idx]
        data = json.loads(json_str)

    except (json.JSONDecodeError, ValueError) as e:
        # Dump output for debugging if parsing fails
        print(f"DEBUG: Raw output was:\n{raw_output}", file=sys.stderr)
        raise ValueError(f"Failed to parse JSON from btcli output: {e}")

    # Extract stake info
    stake_map = data.get("stake_info", {})
    if not stake_map:
        # Fallback: sometimes btcli structure varies or is empty
        return [], []

    hotkeys_ss58 = list(stake_map.keys())
    valid_hotkeys_bytes32 = []
    valid_amounts = []

    for hk_ss58 in hotkeys_ss58:
        stake_entries = stake_map.get(hk_ss58, [])

        # Filter entries strictly by netuid
        total_value_tao = 0.0
        for entry in stake_entries:
            # btcli sometimes returns netuid as str, sometimes int
            entry_netuid = entry.get("netuid")
            if str(entry_netuid) == str(netuid):
                total_value_tao += entry.get("stake_value", 0)

        # Skip if no stake on this specific subnet
        if total_value_tao <= 0:
            continue

        try:
            # Convert SS58 to raw bytes (bytes32) using shared utility
            pub32_bytes = ss58_to_bytes(hk_ss58)

            valid_hotkeys_bytes32.append(pub32_bytes)
            valid_amounts.append(total_value_tao)

        except Exception as e:
            print(f"WARNING: Skipping hotkey {hk_ss58} due to conversion error: {e}", file=sys.stderr)

    return valid_hotkeys_bytes32, valid_amounts