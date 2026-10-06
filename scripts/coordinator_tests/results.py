"""Test selection, execution evidence, and atomic coverage aggregation."""

import collections
import hashlib
import json
from pathlib import Path


def test_names(output: str) -> list[str]:
    return [line for line in output.splitlines()
            if line.startswith(("Test", "Example", "Fuzz")) and not any(c.isspace() for c in line)]


def partition(names: list[str], count: int) -> list[list[str]]:
    if not names or len(set(names)) != len(names) or count < 1:
        raise ValueError("expected unique tests and a positive shard count")
    # Spread related, often similarly expensive tests without a stale allowlist
    # or duration manifest. Discovery, not the partition, owns suite membership.
    ordered = sorted(names, key=lambda name: hashlib.sha256(name.encode()).digest())
    return [ordered[i::count] for i in range(min(count, len(names)))]


def verify_events(path: Path, expected: list[str] | None, packages: list[str] | None = None) -> dict:
    terminal = collections.Counter()
    counts = collections.Counter()
    failed = False
    finished_packages = collections.Counter()
    with path.open() as stream:
        for line in stream:
            event = json.loads(line)
            action, name = event.get("Action"), event.get("Test")
            failed |= action == "fail"
            if not name and event.get("Package") and action in ("pass", "skip"):
                finished_packages[event["Package"]] += 1
            if name and action in ("pass", "skip", "fail"):
                counts[action] += 1
                if "/" not in name:
                    terminal[name] += 1
    if failed:
        raise ValueError("test or package failure in JSON results")
    if not finished_packages:
        raise ValueError("missing package completion in JSON results")
    if packages is not None and finished_packages != collections.Counter(packages):
        raise ValueError(f"package membership mismatch: expected={packages}, finished={dict(finished_packages)}")
    if expected is not None and terminal != collections.Counter(expected):
        missing = sorted(set(expected) - terminal.keys())
        extra = sorted(terminal.keys() - set(expected))
        duplicate = sorted(name for name, count in terminal.items() if count != 1)
        raise ValueError(f"test membership mismatch: missing={missing}, extra={extra}, duplicate={duplicate}")
    return dict(counts)


def merge_coverage(paths: list[Path], destination: Path) -> None:
    blocks: dict[str, tuple[int, int]] = {}
    for path in paths:
        with path.open() as stream:
            if stream.readline().strip() != "mode: atomic":
                raise ValueError(f"missing atomic coverage header: {path}")
            found = False
            for line in stream:
                location, statements, count = line.split()
                statements, count = int(statements), int(count)
                if statements < 0 or count < 0:
                    raise ValueError(f"negative coverage value: {path}")
                old_statements, old_count = blocks.get(location, (statements, 0))
                if old_statements != statements:
                    raise ValueError(f"inconsistent coverage block: {location}")
                blocks[location] = statements, old_count + count
                found = True
            if not found:
                raise ValueError(f"empty coverage profile: {path}")
    if not blocks:
        raise ValueError("no coverage profiles")
    with destination.open("w") as stream:
        stream.write("mode: atomic\n")
        for location, (statements, count) in sorted(blocks.items()):
            stream.write(f"{location} {statements} {count}\n")
