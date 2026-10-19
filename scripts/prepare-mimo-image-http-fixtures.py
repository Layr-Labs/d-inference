#!/usr/bin/env python3
"""Prepare hash-pinned MiMo text metadata and deterministic real PNGs, never weights."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import struct
import subprocess
import zlib

SPEC = importlib.util.spec_from_file_location(
    "mimo_audio_pins", Path(__file__).with_name("prepare-mimo-audio-fixtures.py"))
PINS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PINS)
NAMES = ("config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja")


def png(rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    # Fixed uncompressed DEFLATE avoids compressor-version-dependent fixture bytes.
    row = b"\0" + bytes(rgb) * 28
    pixels = row * 28
    compressed = b"\x78\x01\x01" + struct.pack("<HH", len(pixels), 65535 - len(pixels))
    compressed += pixels + struct.pack(">I", zlib.adler32(pixels))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 28, 28, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", compressed) + chunk(b"IEND", b""))


def download(name):
    size, _ = PINS.FILES[name]
    return subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                           "--proto", "=https", "--proto-redir", "=https",
                           "--max-time", "60", "--max-filesize", str(size),
                           PINS.BASE_URL + "/" + name], check=True, capture_output=True).stdout


def prepare(output, fetch=download):
    # Fresh private directory: never replace an existing attempt or follow its link.
    output = output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name in NAMES:
        size, digest = PINS.FILES[name]
        data = fetch(name)
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("MiMo HTTP fixture size or SHA-256 mismatch: " + name)
        (output / name).write_bytes(data)
    for name, rgb in (("red-square.png", (255, 0, 0)), ("blue-square.png", (0, 0, 255))):
        (output / name).write_bytes(png(rgb))
    return output.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-env", type=Path, required=True)
    args = parser.parse_args()
    if any(c in str(args.output) for c in "\r\n"):
        raise ValueError("invalid environment path")
    output = prepare(args.output)
    with args.github_env.open("a", encoding="utf-8") as stream:
        stream.write(f"MIMO_CLUSTER_IMAGE_METADATA_DIR={output}\nMIMO_CLUSTER_IMAGE_ASSET_DIR={output}\n")


if __name__ == "__main__":
    main()
