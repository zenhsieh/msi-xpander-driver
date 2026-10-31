#!/usr/bin/env python3
"""Render a local JSON token summary as a 1920x720 PNG on stdout."""

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path


WIDTH, HEIGHT = 1920, 720
BACKGROUND = (11, 17, 29)
PANEL = (24, 35, 53)
MUTED = (147, 170, 196)
WHITE = (237, 244, 252)
ACCENT = (92, 215, 185)

# Five-by-seven glyphs keep the standard-library path independent of system fonts.
GLYPHS = {
    " ": ("00000",) * 7,
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01111", "10000", "10000", "10000", "10000", "10000", "01111"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01111", "10000", "10000", "10111", "10001", "10001", "01111"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
    "J": ("00111", "00010", "00010", "00010", "10010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "Q": ("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "10101", "01010"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "Y": ("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
    "Z": ("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "10000", "11110", "00001", "00001", "11110"),
    "6": ("01111", "10000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00001", "11110"),
    ",": ("00000", "00000", "00000", "00000", "00100", "00100", "01000"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
    ".": ("00000", "00000", "00000", "00000", "00000", "00100", "00100"),
    "/": ("00001", "00001", "00010", "00100", "01000", "10000", "10000"),
}


def nonnegative_int(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a nonnegative integer")
    return value


def load_summary(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    usage = data["token_usage"]
    today = nonnegative_int(usage["today"], "token_usage.today")
    month = nonnegative_int(usage["month"], "token_usage.month")
    sessions = []
    for item in data["sessions"]:
        if not isinstance(item["name"], str):
            raise ValueError("session name must be text")
        sessions.append((item["name"], nonnegative_int(item["context"], "session context")))
    if len(sessions) > 7:
        raise ValueError("at most seven sessions fit in one frame")
    return today, month, sessions


def rectangle(pixels, x, y, width, height, color):
    row = bytes(color) * width
    for yy in range(y, y + height):
        start = (yy * WIDTH + x) * 3
        pixels[start:start + width * 3] = row


def label(pixels, x, y, value, scale, color):
    for char in str(value).upper():
        glyph = GLYPHS.get(char, GLYPHS[" "])
        for yy, row in enumerate(glyph):
            for xx, bit in enumerate(row):
                if bit == "1":
                    rectangle(pixels, x + xx * scale, y + yy * scale, scale, scale, color)
        x += 6 * scale


def render(today, month, sessions):
    pixels = bytearray(bytes(BACKGROUND) * (WIDTH * HEIGHT))
    rectangle(pixels, 40, 40, 700, 640, PANEL)
    rectangle(pixels, 770, 40, 1110, 640, PANEL)
    label(pixels, 86, 88, "TOKEN USAGE", 5, WHITE)
    label(pixels, 86, 206, "TODAY", 4, MUTED)
    label(pixels, 86, 266, f"{today:,}", 7, ACCENT)
    label(pixels, 86, 414, "THIS MONTH", 4, MUTED)
    label(pixels, 86, 474, f"{month:,}", 7, WHITE)
    label(pixels, 812, 88, "SESSIONS", 5, WHITE)
    label(pixels, 1430, 96, "CONTEXT", 4, MUTED)
    rectangle(pixels, 812, 158, 1024, 2, MUTED)
    for index, (name, context) in enumerate(sessions):
        y = 190 + index * 65
        label(pixels, 812, y, name[:19], 4, WHITE)
        label(pixels, 1430, y, f"{context:,}", 4, ACCENT)
    if not sessions:
        label(pixels, 812, 210, "NO SESSIONS", 4, MUTED)
    return pixels


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def standard_library_png(pixels):
    stride = WIDTH * 3
    raw = b"".join(b"\x00" + pixels[y * stride:(y + 1) * stride] for y in range(HEIGHT))
    return (b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(raw, 6))
            + png_chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, default=Path("./summary.json"),
                        help="JSON summary file (default: ./summary.json)")
    args = parser.parse_args()
    try:
        pixels = render(*load_summary(args.summary))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    try:
        from PIL import Image
    except ImportError:
        sys.stdout.buffer.write(standard_library_png(pixels))
    else:
        Image.frombytes("RGB", (WIDTH, HEIGHT), bytes(pixels)).save(sys.stdout.buffer, "PNG")


if __name__ == "__main__":
    main()
