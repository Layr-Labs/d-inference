#!/usr/bin/env python3
"""Remove machine-identifying text from benchmark evidence before it is kept.

Reads stdin (or the files named on the command line, rewriting them in place)
and replaces:

  * the current user's home directory with ``~`` and the bare user name with
    ``<user>``;
  * this Mac's host names (``hostname``, ``scutil --get`` names) with ``<host>``;
  * IPv4 addresses other than loopback and the unspecified address with
    ``<addr>``;
  * MAC addresses and link-local/ULA IPv6 addresses with ``<mac>``/``<addr6>``;
  * the hardware serial number and platform UUID with ``<serial>``/``<uuid>``;
  * any extra literal passed with ``--also`` (for a second Mac's names, which
    this process cannot look up) with the replacement given after ``=``.

``--check`` prints the lines that would change and exits 1 if there are any;
nothing is rewritten. Standard library only.
"""

from __future__ import annotations

import argparse
import getpass
import os
import re
import subprocess
import sys

IPV4 = re.compile(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])")
MAC = re.compile(r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])")
IPV6_LOCAL = re.compile(r"(?<![0-9A-Fa-f:])f[cde][0-9a-f]{2}:(?::?[0-9a-f]{1,4}){1,7}(?:%[a-z0-9]+)?")
KEPT_IPV4 = {"0.0.0.0", "255.255.255.255"}


def _command_output(arguments: list[str]) -> str:
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def local_literals() -> list[tuple[str, str]]:
    """Literal replacements derived from this Mac, longest first."""
    pairs: list[tuple[str, str]] = []
    home = os.path.expanduser("~")
    user = getpass.getuser()
    if home and home != "/":
        pairs.append((home, "~"))
    for name in {
        _command_output(["hostname"]),
        _command_output(["hostname", "-s"]),
        _command_output(["scutil", "--get", "LocalHostName"]),
        _command_output(["scutil", "--get", "ComputerName"]),
        _command_output(["scutil", "--get", "HostName"]),
    }:
        if len(name) >= 4:
            pairs.append((name, "<host>"))
    hardware = _command_output(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
    for key, replacement in (("IOPlatformSerialNumber", "<serial>"), ("IOPlatformUUID", "<uuid>")):
        match = re.search(rf'"{key}" = "([^"]+)"', hardware)
        if match and len(match.group(1)) >= 6:
            pairs.append((match.group(1), replacement))
    if len(user) >= 3:
        pairs.append((f"/Users/{user}", "~"))
        pairs.append((user, "<user>"))
    pairs.sort(key=lambda pair: len(pair[0]), reverse=True)
    return pairs


def _ipv4_replacement(match: re.Match[str]) -> str:
    text = match.group(0)
    octets = [int(group) for group in match.groups()]
    if any(octet > 255 for octet in octets):
        return text  # not an address (for example a version string)
    if octets[0] == 127 or text in KEPT_IPV4:
        return text
    return "<addr>"


def redact(text: str, literals: list[tuple[str, str]]) -> str:
    for literal, replacement in literals:
        text = text.replace(literal, replacement)
        lowered = literal.lower()
        if lowered != literal:
            text = text.replace(lowered, replacement)
    text = re.sub(r"/Users/[A-Za-z0-9._-]+", "~", text)
    text = IPV4.sub(_ipv4_replacement, text)
    text = MAC.sub("<mac>", text)
    text = IPV6_LOCAL.sub("<addr6>", text)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*", help="files to rewrite in place; stdin to stdout when none")
    parser.add_argument("--also", action="append", default=[], metavar="LITERAL=REPLACEMENT")
    parser.add_argument("--check", action="store_true", help="report, do not rewrite; exit 1 on any hit")
    arguments = parser.parse_args()

    literals = local_literals()
    for item in arguments.also:
        literal, _, replacement = item.partition("=")
        if len(literal) >= 3:
            literals.append((literal, replacement or "<redacted>"))
    literals.sort(key=lambda pair: len(pair[0]), reverse=True)

    if not arguments.files:
        sys.stdout.write(redact(sys.stdin.read(), literals))
        return 0

    hits = 0
    for path in arguments.files:
        try:
            with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
                original = handle.read()
        except (OSError, UnicodeError) as error:
            print(f"redact: skipped {path}: {error}", file=sys.stderr)
            continue
        cleaned = redact(original, literals)
        if cleaned == original:
            continue
        if arguments.check:
            for before, after in zip(original.splitlines(), cleaned.splitlines()):
                if before != after:
                    hits += 1
                    print(f"{path}: {after[:200]}")
        else:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
                handle.write(cleaned)
    return 1 if (arguments.check and hits) else 0


if __name__ == "__main__":
    sys.exit(main())
