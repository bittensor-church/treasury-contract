from substrateinterface.utils.ss58 import ss58_decode

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def decode_ss58_to_bytes32(ss58_address):
    recipient_decoded_hex = ss58_decode(ss58_address)
    return bytes.fromhex(clean_hex(recipient_decoded_hex))

def parse_hotkey(hotkey_str):
    """Accept hotkey as hex (0x-prefixed or not) or SS58 address."""
    s = hotkey_str.strip()
    if s.startswith("0x") or all(c in "0123456789abcdefABCDEF" for c in s):
        return bytes.fromhex(clean_hex(s).zfill(64))
    return decode_ss58_to_bytes32(s)