from substrateinterface.utils.ss58 import ss58_decode

def clean_hex(hex_str):
    if hex_str.startswith("0x"):
        return hex_str[2:]
    return hex_str

def decode_ss58_to_bytes32(ss58_address):
    recipient_decoded_hex = ss58_decode(ss58_address)
    return bytes.fromhex(clean_hex(recipient_decoded_hex))

def parse_hotkey(hotkey_str):
    return bytes.fromhex(clean_hex(hotkey_str).zfill(64))