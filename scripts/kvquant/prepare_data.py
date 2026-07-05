#!/usr/bin/env python3
"""Prepare local KV quant benchmark data scaffolding.

This script is intentionally offline by default. It creates a deterministic data
directory with a README and manifest that point at the small in-repo smoke
fixtures. External corpus download support can be wired in later without
changing the benchmark directory shape.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO_ROOT / "provider-swift" / "Benchmarks" / "KVQuant" / "data"

README_TEXT = """# KV Quant Benchmark Data

This directory is prepared for local KV quant benchmark inputs.

The default scaffold is fully offline and deterministic. It references the
small prompt fixtures checked into `provider-swift/Benchmarks/KVQuant/prompts/`:

- `output-smoke.jsonl`: deterministic output-quality prompts.
- `niah-smoke.jsonl`: compact synthetic needle-in-a-haystack templates.

No external data is downloaded unless a future downloader is implemented and
explicitly requested.
"""


def manifest() -> dict:
    return {
        "schema_version": 1,
        "description": "Offline KV quant benchmark data manifest.",
        "datasets": [
            {
                "name": "output-smoke",
                "kind": "prompt_fixture",
                "path": "../prompts/output-smoke.jsonl",
                "external": False,
            },
            {
                "name": "niah-smoke",
                "kind": "prompt_fixture",
                "path": "../prompts/niah-smoke.jsonl",
                "external": False,
            },
        ],
        "external_downloads": [],
    }


def prepare(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "README.md").write_text(README_TEXT, encoding="utf-8")
    (out / "manifest.json").write_text(
        json.dumps(manifest(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare offline KV quant benchmark data scaffolding.")
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        help=f"Output data directory (default: {DEFAULT_OUT.relative_to(REPO_ROOT)})",
    )
    parser.add_argument(
        "--download-wikitext2",
        action="store_true",
        help="Placeholder only. No external data is downloaded by this script yet.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    out = args.out.expanduser()
    if not out.is_absolute():
        out = (Path.cwd() / out).resolve()

    prepare(out)
    print(f"Prepared KV quant data scaffold at {out}")

    if args.download_wikitext2:
        print(
            "--download-wikitext2 is a placeholder; no external data was downloaded. "
            "Add an explicit downloader once the corpus source and license checks are finalized.",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
