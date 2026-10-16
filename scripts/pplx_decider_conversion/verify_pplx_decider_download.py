#!/usr/bin/env python3
"""Verify a downloaded pplx-decider, base-model or served-pack tree.

No downloads and no MLX imports. `decider` checks the pinned release manifest
and the extra pins; `base` and `reference` check the download marker and the
Hub download metadata of the conformance inputs. A successful run without
--hash-shards never claims weight-shard payload verification.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from pplx_decider_provenance import (
    BASE_REPO,
    BASE_REVISION,
    REFERENCE_REPO,
    REFERENCE_REVISION,
    sha256_file,
    verify_hub_snapshot,
    verify_release,
)


def verify(kind: str, source: Path, hash_shards: bool) -> dict:
    if kind == "decider":
        return verify_release(source, hash_shards=hash_shards)
    repo, revision = (BASE_REPO, BASE_REVISION) if kind == "base" else (REFERENCE_REPO, REFERENCE_REVISION)
    return verify_hub_snapshot(source, repo, revision, hash_shards=hash_shards)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--kind", choices=("decider", "base", "reference"), default="decider")
    parser.add_argument("--hash-shards", action="store_true", help="SHA-256 every weight shard.")
    parser.add_argument(
        "--output-manifest",
        type=Path,
        help="Write a new exclusive receipt after successful full hashing; never overwrite.",
    )
    args = parser.parse_args(argv)
    if args.output_manifest is not None and not args.hash_shards:
        parser.error("--output-manifest requires --hash-shards")
    os.umask(0o077)
    report = verify(args.kind, args.source, args.hash_shards)
    report["verifier_sha256"] = sha256_file(Path(__file__))
    report["provenance_helper_sha256"] = sha256_file(Path(__file__).with_name("pplx_decider_provenance.py"))
    if report["ok"] and args.output_manifest is not None:
        with args.output_manifest.open("x", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if report["ok"] else 4


if __name__ == "__main__":
    raise SystemExit(main())
