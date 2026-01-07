import json
import sys
from pathlib import Path
from web3 import Web3

def get_web3_provider(rpc_url: str) -> Web3:
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConnectionError(f"Failed to connect to RPC URL: {rpc_url}")
    return w3

def load_contract(w3: Web3, contract_address: str, artifact_path: Path):
    try:
        if not artifact_path.exists():
            artifact_path = Path(artifact_path.name)
        if not artifact_path.exists():
            raise FileNotFoundError(f"Artifact not found at {artifact_path}")
        abi = json.loads(artifact_path.read_text())["abi"]
    except (FileNotFoundError, KeyError) as e:
        print(f"Error loading ABI: {e}", file=sys.stderr)
        print("Using minimal fallback ABI...", file=sys.stderr)
        abi = [
            # Governor
            {
                "inputs": [
                    {"internalType": "address[]", "name": "targets", "type": "address[]"},
                    {"internalType": "uint256[]", "name": "values", "type": "uint256[]"},
                    {"internalType": "bytes[]", "name": "calldatas", "type": "bytes[]"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "propose",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address[]", "name": "targets", "type": "address[]"},
                    {"internalType": "uint256[]", "name": "values", "type": "uint256[]"},
                    {"internalType": "bytes[]", "name": "calldatas", "type": "bytes[]"},
                    {"internalType": "bytes32", "name": "descriptionHash", "type": "bytes32"}
                ],
                "name": "queue",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address[]", "name": "targets", "type": "address[]"},
                    {"internalType": "uint256[]", "name": "values", "type": "uint256[]"},
                    {"internalType": "bytes[]", "name": "calldatas", "type": "bytes[]"},
                    {"internalType": "bytes32", "name": "descriptionHash", "type": "bytes32"}
                ],
                "name": "execute",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "payable",
                "type": "function"
            },
            # TreasuryVault - addStake removed
            {
                "inputs": [
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "uint256", "name": "netuid", "type": "uint256"}
                ],
                "name": "removeStake",
                "outputs": [],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "bytes32", "name": "fromValidator", "type": "bytes32"},
                    {"internalType": "bytes32", "name": "toValidator", "type": "bytes32"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "uint256", "name": "netuid", "type": "uint256"}
                ],
                "name": "transferAlpha",
                "outputs": [],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "uint16", "name": "netuid", "type": "uint16"},
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"}
                ],
                "name": "registerNeuron",
                "outputs": [{"internalType": "bool", "name": "", "type": "bool"}],
                "stateMutability": "payable",
                "type": "function"
            }
        ]

    return w3.eth.contract(
        address=Web3.to_checksum_address(contract_address),
        abi=abi
    )