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
    except (FileNotFoundError, KeyError, AttributeError):
        abi = [
            {
                "inputs": [
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "proposeNativeTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "proposeOrVoteNativeTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "target", "type": "address"},
                    {"internalType": "uint16", "name": "netuid", "type": "uint16"},
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "proposeAlphaTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "target", "type": "address"},
                    {"internalType": "uint16", "name": "netuid", "type": "uint16"},
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "proposeOrVoteAlphaTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "token", "type": "address"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "proposeERC20Transfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "token", "type": "address"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "proposeOrVoteERC20Transfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "queueNativeTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "executeNativeTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "payable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "target", "type": "address"},
                    {"internalType": "uint16", "name": "netuid", "type": "uint16"},
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "queueAlphaTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "target", "type": "address"},
                    {"internalType": "uint16", "name": "netuid", "type": "uint16"},
                    {"internalType": "bytes32", "name": "hotkey", "type": "bytes32"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "executeAlphaTransfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "payable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "token", "type": "address"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "queueERC20Transfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "token", "type": "address"},
                    {"internalType": "address", "name": "recipient", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                    {"internalType": "string", "name": "description", "type": "string"}
                ],
                "name": "executeERC20Transfer",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "payable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "uint256", "name": "proposalId", "type": "uint256"},
                    {"internalType": "uint8", "name": "support", "type": "uint8"}
                ],
                "name": "castVote",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "nonpayable",
                "type": "function"
            }
        ]

    return w3.eth.contract(
        address=Web3.to_checksum_address(contract_address),
        abi=abi
    )