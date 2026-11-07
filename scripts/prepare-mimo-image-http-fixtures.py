#!/usr/bin/env python3
"""Prepare hash-pinned MiMo text metadata and deterministic real PNGs, never weights."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import urllib.parse
import zlib

from verified_download_cache import cached

SPEC = importlib.util.spec_from_file_location(
    "mimo_audio_pins", Path(__file__).with_name("prepare-mimo-audio-fixtures.py"))
PINS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PINS)
NAMES = ("config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja")
DOWNLOAD_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = (1, 3)
DEADLINE_SECONDS = 120
ATTEMPT_SECONDS = 60
# curl exit codes of a cut or failed transfer: name resolution (6), connect
# (7), HTTP/2 framing (16, 92), partial file (18), timeout (28), TLS handshake
# (35), empty reply (52), send (55) and receive (56). Plain `--retry` skips 18
# and 56; `--retry-all-errors` would also retry 4xx and an oversize body (63).
TRANSIENT_CURL_EXITS = {6, 7, 16, 18, 28, 35, 52, 55, 56, 92}
# curl itself never follows a redirect: each hop is checked against the
# requested origin before it is requested, so a fixture download never leaves
# its host. The cap is urllib's, as in prepare-prompt-fixtures.py.
REDIRECT_STATUSES = {"301", "302", "303", "307", "308"}
MAX_REDIRECTS = 10
DEFAULT_PORTS = {"http": 80, "https": 443}


class TransientTransfer(ValueError):
    """A transfer that the network cut or the server failed; another attempt may succeed."""


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


def origin(url):
    parts = urllib.parse.urlsplit(url)
    return parts.scheme, parts.hostname, parts.port or DEFAULT_PORTS.get(parts.scheme)


def fetch_once(name, size, seconds):
    url = PINS.BASE_URL + "/" + name
    requested, stop = origin(url), time.monotonic() + seconds
    with tempfile.TemporaryDirectory() as directory:
        body = Path(directory) / "body"
        for _ in range(MAX_REDIRECTS + 1):
            # curl writes no file for an empty body: a redirect's body must not
            # stand in for the final one.
            body.unlink(missing_ok=True)
            result = subprocess.run(["curl", "--silent", "--show-error", "--proto", "=https",
                                     "--max-time", f"{max(1.0, stop - time.monotonic()):.3f}",
                                     "--max-filesize", str(size), "--output", str(body),
                                     "--write-out", "%{http_code} %{redirect_url}", url],
                                    capture_output=True, text=True)
            if result.returncode in TRANSIENT_CURL_EXITS:
                raise TransientTransfer(f"MiMo HTTP fixture transfer failed (curl {result.returncode}): {name}")
            if result.returncode != 0:
                raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
            status, _, location = result.stdout.strip().partition(" ")
            if status not in REDIRECT_STATUSES or not location:
                break
            # A plain-HTTP downgrade is a different origin too.
            if origin(location) != requested:
                raise ValueError("MiMo HTTP fixture redirected to another origin: " + name)
            url = location
        else:
            raise ValueError("MiMo HTTP fixture exceeded the redirect limit: " + name)
        if status.isdecimal() and 500 <= int(status) < 600:
            raise TransientTransfer(f"MiMo HTTP fixture returned HTTP {status}: {name}")
        if status != "200":
            raise ValueError(f"MiMo HTTP fixture returned HTTP {status}: {name}")
        data = body.read_bytes() if body.exists() else b""
    if len(data) < size:
        raise TransientTransfer("MiMo HTTP fixture body ended before its pinned size: " + name)
    return data


def download(name):
    # A wrong digest, an oversize body or a cross-origin redirect still fails
    # at once, here or in prepare.
    size, _ = PINS.FILES[name]
    deadline = time.monotonic() + DEADLINE_SECONDS
    for attempt in range(DOWNLOAD_ATTEMPTS):
        try:
            # curl reads --max-time 0 as no limit, so an attempt gets at least 1 s.
            return fetch_once(name, size, max(1.0, min(ATTEMPT_SECONDS, deadline - time.monotonic())))
        except TransientTransfer as error:
            if attempt + 1 == DOWNLOAD_ATTEMPTS:
                raise
            delay = RETRY_BACKOFF_SECONDS[attempt]
            if time.monotonic() + delay >= deadline:
                raise ValueError("MiMo HTTP fixture download timed out: " + name) from error
            time.sleep(delay)


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
    parser.add_argument("--cache", type=Path, help="content-addressed directory of verified downloads")
    args = parser.parse_args()
    if any(c in str(args.output) for c in "\r\n"):
        raise ValueError("invalid environment path")
    fetch = download if args.cache is None else cached(download, args.cache, lambda name: PINS.FILES[name][1])
    output = prepare(args.output, fetch)
    with args.github_env.open("a", encoding="utf-8") as stream:
        stream.write(f"MIMO_CLUSTER_IMAGE_METADATA_DIR={output}\nMIMO_CLUSTER_IMAGE_ASSET_DIR={output}\n")


if __name__ == "__main__":
    main()
