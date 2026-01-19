import os
import sys
import argparse
from web3 import Web3

def add_web3_arguments(parser: argparse.ArgumentParser, requires_private_key: bool = True):
    """Adds standard Web3 arguments to the parser."""
    parser.add_argument("--rpc-url", required=True, help="RPC endpoint URL")
    if requires_private_key:
        parser.add_argument("--private-key", default=None, help="Private key (or set PRIVATE_KEY env var)")
        parser.add_argument("--force-gas-price-gwei", type=float, help="Force a specific Gas Price in Gwei")

def setup_web3_connection(rpc_url: str):
    """Establishes Web3 connection."""
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        raise ConnectionError(f"Failed to connect to RPC URL: {rpc_url}")
    return w3

def get_account(w3: Web3, private_key_arg: str = None):
    """Loads account from argument or environment variable."""
    private_key = private_key_arg or os.getenv("PRIVATE_KEY")
    if not private_key:
        raise SystemExit("Error: Set PRIVATE_KEY env var or pass --private-key")

    try:
        account = w3.eth.account.from_key(private_key)
        return account
    except Exception as e:
        raise SystemExit(f"Invalid Private Key: {e}")

def setup_web3_with_account(args):
    """Helper to setup both Web3 and Account from parsed args."""
    try:
        w3 = setup_web3_connection(args.rpc_url)
        account = get_account(w3, args.private_key)
        return w3, account
    except Exception as e:
        print(f"CRITICAL ERROR: {e}", file=sys.stderr)
        sys.exit(1)