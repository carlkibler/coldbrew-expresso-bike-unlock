"""
CH9329 USB-HID serial bridge driver.

CH9329 receives 8-byte HID keyboard reports over UART (9600 8N1) and forwards
them as USB HID keystrokes to the host it's plugged into (the bike).

Report format (8 bytes):
  [0x57, 0xAB, 0x00, 0x02, 0x08, MOD, 0x00, K1, K2, K3, K4, K5, K6, CHECKSUM]

Actually the CH9329 uses a slightly different framing — 14-byte packet:
  57 AB 00 02 08  <MOD> 00 <K1> <K2> <K3> <K4> <K5> <K6> <SUM>
where SUM = (sum of bytes 2..12) & 0xFF

HID usage codes for keys we need:
  F2           = 0x3B
  Return/Enter = 0x28
  Backspace    = 0x2A
  Space        = 0x2C
  Escape       = 0x29
  a-z          = 0x04-0x1D
  0-9          = 0x27 (0), 0x1E-0x26 (1-9)
  - (hyphen)   = 0x2D
  / (slash)    = 0x38
  . (period)   = 0x37
  _ (underscore) = 0x2D + SHIFT

Modifier byte:
  LEFT_CTRL  = 0x01
  LEFT_SHIFT = 0x02
  LEFT_ALT   = 0x04
  LEFT_GUI   = 0x08
"""

import time
import serial

# Modifier constants
MOD_NONE  = 0x00
MOD_SHIFT = 0x02
MOD_ALT   = 0x04
MOD_CTRL  = 0x01

# HID usage codes
HID_ENTER  = 0x28
HID_ESC    = 0x29
HID_BKSP   = 0x2A
HID_SPACE  = 0x2C
HID_F2     = 0x3B
HID_MINUS  = 0x2D  # also underscore with SHIFT
HID_SLASH  = 0x38
HID_PERIOD = 0x37
HID_SEMICOLON = 0x33

# ASCII char → (hid_usage, modifier)
_CHAR_MAP: dict[str, tuple[int, int]] = {}

def _build_char_map() -> None:
    for i, c in enumerate("abcdefghijklmnopqrstuvwxyz"):
        _CHAR_MAP[c] = (0x04 + i, MOD_NONE)
        _CHAR_MAP[c.upper()] = (0x04 + i, MOD_SHIFT)
    _CHAR_MAP['1'] = (0x1E, MOD_NONE); _CHAR_MAP['!'] = (0x1E, MOD_SHIFT)
    _CHAR_MAP['2'] = (0x1F, MOD_NONE); _CHAR_MAP['@'] = (0x1F, MOD_SHIFT)
    _CHAR_MAP['3'] = (0x20, MOD_NONE); _CHAR_MAP['#'] = (0x20, MOD_SHIFT)
    _CHAR_MAP['4'] = (0x21, MOD_NONE); _CHAR_MAP['$'] = (0x21, MOD_SHIFT)
    _CHAR_MAP['5'] = (0x22, MOD_NONE); _CHAR_MAP['%'] = (0x22, MOD_SHIFT)
    _CHAR_MAP['6'] = (0x23, MOD_NONE); _CHAR_MAP['^'] = (0x23, MOD_SHIFT)
    _CHAR_MAP['7'] = (0x24, MOD_NONE); _CHAR_MAP['&'] = (0x24, MOD_SHIFT)
    _CHAR_MAP['8'] = (0x25, MOD_NONE); _CHAR_MAP['*'] = (0x25, MOD_SHIFT)
    _CHAR_MAP['9'] = (0x26, MOD_NONE); _CHAR_MAP['('] = (0x26, MOD_SHIFT)
    _CHAR_MAP['0'] = (0x27, MOD_NONE); _CHAR_MAP[')'] = (0x27, MOD_SHIFT)
    _CHAR_MAP['\n'] = (HID_ENTER, MOD_NONE)
    _CHAR_MAP[' '] = (HID_SPACE, MOD_NONE)
    _CHAR_MAP['-'] = (HID_MINUS, MOD_NONE)
    _CHAR_MAP['_'] = (HID_MINUS, MOD_SHIFT)
    _CHAR_MAP['/'] = (HID_SLASH, MOD_NONE)
    _CHAR_MAP['?'] = (HID_SLASH, MOD_SHIFT)
    _CHAR_MAP['.'] = (HID_PERIOD, MOD_NONE)
    _CHAR_MAP['>'] = (HID_PERIOD, MOD_SHIFT)
    _CHAR_MAP[';'] = (HID_SEMICOLON, MOD_NONE)
    _CHAR_MAP[':'] = (HID_SEMICOLON, MOD_SHIFT)
    _CHAR_MAP['='] = (0x2E, MOD_NONE)
    _CHAR_MAP['+'] = (0x2E, MOD_SHIFT)
    _CHAR_MAP['['] = (0x2F, MOD_NONE)
    _CHAR_MAP['{'] = (0x2F, MOD_SHIFT)
    _CHAR_MAP[']'] = (0x30, MOD_NONE)
    _CHAR_MAP['}'] = (0x30, MOD_SHIFT)
    _CHAR_MAP['\\'] = (0x31, MOD_NONE)
    _CHAR_MAP['|'] = (0x31, MOD_SHIFT)
    _CHAR_MAP['`'] = (0x35, MOD_NONE)
    _CHAR_MAP['~'] = (0x35, MOD_SHIFT)
    _CHAR_MAP["'"] = (0x34, MOD_NONE)
    _CHAR_MAP['"'] = (0x34, MOD_SHIFT)
    _CHAR_MAP[','] = (0x36, MOD_NONE)
    _CHAR_MAP['<'] = (0x36, MOD_SHIFT)

_build_char_map()


def _make_packet(hid_usage: int, mod: int = MOD_NONE) -> bytes:
    payload = [0x00, 0x02, 0x08, mod, 0x00, hid_usage, 0x00, 0x00, 0x00, 0x00, 0x00]
    checksum = sum(payload) & 0xFF
    return bytes([0x57, 0xAB] + payload + [checksum])


def _release_packet() -> bytes:
    payload = [0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    checksum = sum(payload) & 0xFF
    return bytes([0x57, 0xAB] + payload + [checksum])


def open_port(dev: str = "/dev/ttyUSB0") -> serial.Serial:
    return serial.Serial(dev, baudrate=9600, bytesize=8, parity='N', stopbits=1, timeout=1)


def send_key(port: serial.Serial, hid_usage: int, mod: int = MOD_NONE, hold_ms: int = 50) -> None:
    port.write(_make_packet(hid_usage, mod))
    port.flush()
    time.sleep(hold_ms / 1000)
    port.write(_release_packet())
    port.flush()
    time.sleep(0.02)


def type_string(port: serial.Serial, text: str, delay: float = 0.05) -> None:
    for ch in text:
        if ch not in _CHAR_MAP:
            raise ValueError(f"no HID mapping for character {ch!r}")
        usage, mod = _CHAR_MAP[ch]
        send_key(port, usage, mod)
        time.sleep(delay)


def alt_f2(port: serial.Serial) -> None:
    """Open the GNOME run dialog (Alt+F2)."""
    send_key(port, HID_F2, MOD_ALT)
    time.sleep(1.0)


def press_enter(port: serial.Serial) -> None:
    send_key(port, HID_ENTER)
