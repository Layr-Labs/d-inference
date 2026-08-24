#!/usr/bin/env python3

"""Authorize only the reviewed, quarantine-only Lume publication programs."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
from pathlib import Path


EXPECTED_SHA256 = {
    "lume-runtime-publication.py": (
        "73c71cff590a594937eea1f61f3d99e42b5c96b5cb469284595d549445f07580"
    ),
    "build-pinned-lume.sh": (
        "5b5d0cf6c997ee77b657b27e06467d024976c190772c87c872f46983016e3465"
    ),
    "quarantine-sealed-lume-staging.sh": (
        "18cb80ddb7a60582596a9f674188c554b64df162d8803879593737c9ab862341"
    ),
}
EXPECTED_FILE_COUNT = 3
EXPECTED_SELF_TEST_COUNT = 6


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def mismatches(
    content_by_name: dict[str, bytes],
    expected_by_name: dict[str, str],
) -> list[str]:
    failures: list[str] = []
    actual_names = set(content_by_name)
    expected_names = set(expected_by_name)
    for name in sorted(expected_names - actual_names):
        failures.append(f"missing:{name}")
    for name in sorted(actual_names - expected_names):
        failures.append(f"unexpected:{name}")
    for name in sorted(actual_names & expected_names):
        actual = digest(content_by_name[name])
        if actual != expected_by_name[name]:
            failures.append(
                f"digest:{name}:expected={expected_by_name[name]}:actual={actual}"
            )
    return failures


def read_authorized_sources(scripts_directory: Path) -> dict[str, bytes]:
    sources: dict[str, bytes] = {}
    for name in EXPECTED_SHA256:
        path = scripts_directory / name
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(f"publication policy target is not a regular file: {path}")
        sources[name] = path.read_bytes()
    return sources


def run_self_test() -> None:
    fixtures = {
        "helper.py": b"quarantine(source, destination)\n",
        "build.sh": b"publish staging\n",
        "quarantine.sh": b"rename staging quarantine\n",
    }
    expected = {name: digest(content) for name, content in fixtures.items()}
    completed = 0

    if mismatches(fixtures, expected):
        raise AssertionError("exact source set was rejected")
    completed += 1

    for name in sorted(fixtures):
        changed = dict(fixtures)
        changed[name] += b"# destructive regression\n"
        failures = mismatches(changed, expected)
        if len(failures) != 1 or not failures[0].startswith(f"digest:{name}:"):
            raise AssertionError(f"mutation was not isolated for {name}: {failures}")
        completed += 1

    missing = dict(fixtures)
    missing.pop("helper.py")
    if mismatches(missing, expected) != ["missing:helper.py"]:
        raise AssertionError("missing source was not rejected")
    completed += 1

    unexpected = dict(fixtures)
    unexpected["delete.sh"] = b"rm -rf staging\n"
    if mismatches(unexpected, expected) != ["unexpected:delete.sh"]:
        raise AssertionError("unexpected source was not rejected")
    completed += 1

    if completed != EXPECTED_SELF_TEST_COUNT:
        raise AssertionError(
            f"cleanup policy self-test count mismatch: {completed}"
        )
    print(f"lume_publication_cleanup_policy_self_test=exact:{completed}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify reviewed Lume publication source fingerprints"
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--scripts-directory")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.self_test:
        run_self_test()
    if arguments.scripts_directory is None:
        if arguments.self_test:
            return 0
        raise SystemExit("--scripts-directory is required")

    if len(EXPECTED_SHA256) != EXPECTED_FILE_COUNT:
        raise SystemExit("publication policy file count mismatch")
    scripts_directory = Path(arguments.scripts_directory).resolve(strict=True)
    failures = mismatches(
        read_authorized_sources(scripts_directory),
        EXPECTED_SHA256,
    )
    if failures:
        raise SystemExit(
            "Lume publication source changed; review quarantine-only cleanup "
            "and update its authorized SHA-256 fingerprint:\n"
            + "\n".join(f"- {failure}" for failure in failures)
        )
    print(f"lume_publication_cleanup_policy=exact:{EXPECTED_FILE_COUNT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
