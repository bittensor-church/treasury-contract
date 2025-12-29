import hashlib
import base58  # Requires: pip install base58

BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SS58_PREFIX = b"SS58PRE"

def b58encode(data: bytes) -> str:
    """
    Custom Base58 encoder implementation to match specific SS58 formatting requirements.
    """
    num = int.from_bytes(data, "big")
    encoded = ""
    while num > 0:
        num, rem = divmod(num, 58)
        encoded = BASE58_ALPHABET[rem] + encoded
    leading = 0
    for byte in data:
        if byte == 0:
            leading += 1
        else:
            break
    return "1" * leading + encoded

def h160_to_ss58(h160: str, ss58_format: int = 42) -> str:
    """
    Converts 0x EVM address to SS58 address.
    Used to derive Coldkey from Contract Address.
    """
    h160 = h160.lower().removeprefix("0x")
    if len(h160) != 40:
        raise ValueError("Address must be 20 bytes (40 hex chars)")

    addr_bytes = bytes.fromhex(h160)
    prefixed = b"evm:" + addr_bytes
    public_key = hashlib.blake2b(prefixed, digest_size=32).digest()

    if ss58_format < 64:
        prefix = bytes([ss58_format])
    else:
        ss58_format |= 0b01000000
        prefix = bytes([ss58_format & 0xFF, (ss58_format >> 8) & 0xFF])

    payload = prefix + public_key
    checksum = hashlib.blake2b(SS58_PREFIX + payload, digest_size=64).digest()[:2]

    return b58encode(payload + checksum)

def ss58_to_bytes(ss58_address: str) -> bytes:
    """
    Decodes SS58 address to raw 32 bytes public key.
    """
    # 1. Decode Base58
    try:
        data = base58.b58decode(ss58_address)
    except Exception as e:
        raise ValueError(f"Invalid Base58 string: {e}")

    # 2. Determine prefix length and extract pubkey
    if data[0] < 64:
        prefix = data[:1]
        pubkey = data[1:33]
        checksum = data[33:35]
    else:
        prefix = data[:2]
        pubkey = data[2:34]
        checksum = data[34:36]

    # 3. Verify checksum
    h = hashlib.blake2b(SS58_PREFIX + prefix + pubkey, digest_size=64).digest()
    if checksum != h[:2]:
        raise ValueError("Invalid SS58 checksum")

    return pubkey

def ss58_to_pub32(ss58_address: str) -> str:
    """
    Converts SS58 address to a hex string (0x...).
    This restores the functionality of the original ss58_to_pub32 function.
    """
    pubkey_bytes = ss58_to_bytes(ss58_address)
    return "0x" + pubkey_bytes.hex()