#!/usr/bin/env python3
"""Verify the pinned BF16 tree with explicit source-payload coverage.

This isolated hardening copy performs no downloads or MLX imports. A successful
metadata-only check never claims source payload verification. Full hashing
requires valid expected digests for every pinned shard before reading payloads.
The original September 10 verifier and receipts remain untouched.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from qwen38_provenance import METADATA_PINS, sha256_file, verify_source

VOLUME = Path("/Volumes/Models Repository ")
DEST = VOLUME / "DarkBloom" / "qwen38-next-20260910" / "downloads" / "Qwen-Qwen3.8-Flash-Next-de4b8e4d"
PINS = METADATA_PINS


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEST)
    parser.add_argument(
        "--hash-shards",
        action="store_true",
        help="SHA-256 every pinned shard; fails on missing expected hashes or incomplete coverage.",
    )
    parser.add_argument(
        "--output-manifest",
        type=Path,
        help="Write a new exclusive source digest receipt after successful full hashing; never overwrite.",
    )
    args = parser.parse_args(argv)
    if args.output_manifest is not None and not args.hash_shards:
        parser.error("--output-manifest requires --hash-shards")
    os.umask(0o077)
    report = verify_source(args.source, hash_shards=args.hash_shards)
    report["verifier_sha256"] = sha256_file(Path(__file__))
    report["provenance_helper_sha256"] = sha256_file(Path(__file__).with_name("qwen38_provenance.py"))
    if report["ok"] and args.output_manifest is not None:
        # No directory creation: the owner must select existing available storage.
        with args.output_manifest.open("x", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if report["ok"] else 4


if __name__ == "__main__":
    raise SystemExit(main())
