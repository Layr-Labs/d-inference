#!/usr/bin/env python3
"""Fail when documentation-sensitive source changes omit canonical docs."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RULES = ROOT / "scripts" / "docs-impact-rules.json"
OVERRIDE_LABEL = "docs-not-needed"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.getenv("DOCS_IMPACT_BASE", "origin/master"))
    parser.add_argument("--rules", type=Path, default=DEFAULT_RULES)
    parser.add_argument(
        "--changed-file",
        action="append",
        default=[],
        help="Supply a changed path directly; repeat for tests or local checks.",
    )
    return parser.parse_args()


def load_rules(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        config = json.load(handle)
    if config.get("version") != 1 or not isinstance(config.get("rules"), list):
        raise ValueError(f"{path}: expected version 1 with a rules list")
    return config


def changed_files(base: str) -> list[str]:
    commands = [
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        ["git", "diff", "--name-only"],
        ["git", "diff", "--cached", "--name-only"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ]
    paths: set[str] = set()
    for command in commands:
        result = subprocess.run(
            command,
            cwd=ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        paths.update(line for line in result.stdout.splitlines() if line)
    return sorted(paths)


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def override_requested() -> bool:
    raw = os.getenv("DOCS_IMPACT_LABELS", "[]")
    labels = json.loads(raw)
    return isinstance(labels, list) and OVERRIDE_LABEL in labels


def violations(config: dict[str, Any], paths: list[str]) -> list[tuple[dict[str, Any], list[str]]]:
    ignored = config.get("ignore_patterns", [])
    source_paths = [path for path in paths if not matches(path, ignored)]
    changed_docs = {path for path in paths if (ROOT / path).is_file()}
    missing: list[tuple[dict[str, Any], list[str]]] = []
    for rule in config["rules"]:
        hits = sorted(path for path in source_paths if matches(path, rule["source_patterns"]))
        if not hits:
            continue
        if changed_docs.isdisjoint(rule["docs_any_of"]):
            missing.append((rule, hits))
    return missing


def main() -> int:
    args = parse_args()
    try:
        config = load_rules(args.rules)
        paths = sorted(set(args.changed_file or changed_files(args.base)))
        if override_requested():
            print(f"docs-impact: bypassed by maintainer label {OVERRIDE_LABEL}")
            return 0
    except (OSError, subprocess.CalledProcessError, ValueError, json.JSONDecodeError) as exc:
        print(f"docs-impact: unable to evaluate documentation impact: {exc}", file=sys.stderr)
        return 2

    missing = violations(config, paths)
    if not missing:
        print(f"docs-impact: {len(paths)} changed file(s), canonical documentation coverage OK")
        return 0

    for rule, hits in missing:
        print(f"docs-impact: {rule['name']} source changed without canonical documentation", file=sys.stderr)
        for path in hits:
            print(f"  source: {path}", file=sys.stderr)
        print("  update one of:", file=sys.stderr)
        for path in rule["docs_any_of"]:
            print(f"    - {path}", file=sys.stderr)
    print(
        f"docs-impact: update the mapped docs or ask a maintainer to apply {OVERRIDE_LABEL}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
