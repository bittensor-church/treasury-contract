import json
import sys
from pathlib import Path
from web3 import Web3

def get_web3_provider(rpc_url: str) -> Web3:
    """Initializes and checks Web3 connection."""
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConnectionError(f"Failed to connect to RPC URL: {rpc_url}")
    return w3

def load_contract(w3: Web3, contract_address: str, artifact_path: Path):
    """Loads a contract instance using ABI from a Forge artifact."""
    try:
        # Fallback logic for artifact path
        if not artifact_path.exists():
            # Try looking in current directory as fallback
            artifact_path = Path(artifact_path.name)

        if not artifact_path.exists():
            raise FileNotFoundError(f"Artifact not found at {artifact_path}")

        abi = json.loads(artifact_path.read_text())["abi"]
    except (FileNotFoundError, KeyError) as e:
        print(f"Error loading ABI: {e}", file=sys.stderr)
        print("Using minimal fallback ABI...", file=sys.stderr)
        # Minimal ABI containing likely used functions
        abi = [
            {
                "inputs": [
                    {"internalType": "bytes32[]", "name": "hotkeys", "type": "bytes32[]"},
                    {"internalType": "uint256", "name": "netuid", "type": "uint256"},
                    {"internalType": "uint256[]", "name": "amounts", "type": "uint256[]"}
                ],
                "name": "unstakeAndBurn",
                "outputs": [],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"},
                    {"internalType": "uint256", "name": "netuid", "type": "uint256"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"}
                ],
                "name": "stake",
                "outputs": [],
                "stateMutability": "nonpayable",
                "type": "function"
            }
        ]

    return w3.eth.contract(
        address=Web3.to_checksum_address(contract_address),
        abi=abi
    )