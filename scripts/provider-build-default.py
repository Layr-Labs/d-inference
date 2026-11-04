#!/usr/bin/env python3
"""Check the provider's plain-build environment for a target branch.

provider-swift/Package.swift reads DARKBLOOM_RELEASE_ENVIRONMENT and falls back
to a default when it is unset or empty. That default must be prod on master and
dev on dev (docs/developer/build.md). Other branches are not checked. When the
default line cannot be found, the check fails: a change to Package.swift must
not turn the check off.
"""
import argparse
import re
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1] / "provider-swift" / "Package.swift"
EXPECTED = {"master": "prod", "dev": "dev"}
# environment["DARKBLOOM_RELEASE_ENVIRONMENT"]
#     .flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
DEFAULT = re.compile(
    r'environment\["DARKBLOOM_RELEASE_ENVIRONMENT"\]\s*'
    r'\.flatMap\s*\{[^{}]*\}\s*\?\?\s*"([^"]*)"')


def plain_build_default(package_text):
    found = DEFAULT.findall(package_text)
    if len(found) != 1:
        raise ValueError(
            "expected one plain-build default for DARKBLOOM_RELEASE_ENVIRONMENT in "
            f"Package.swift, found {len(found)}; update scripts/provider-build-default.py "
            "with the new form")
    return found[0]


def check(branch, package_text):
    """Return a report line, or raise ValueError when the default is wrong."""
    expected = EXPECTED.get(branch)
    if expected is None:
        return f"target {branch!r}: no plain-build default is required"
    actual = plain_build_default(package_text)
    if actual != expected:
        raise ValueError(
            f"target {branch!r} requires the plain-build default {expected!r}, but "
            f"Package.swift defaults to {actual!r}")
    return f"target {branch!r}: plain-build default is {actual!r}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branch", required=True, help="Target branch name, for example master or dev")
    parser.add_argument("--package", type=Path, default=PACKAGE)
    args = parser.parse_args()
    try:
        print(check(args.branch, args.package.read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        sys.exit(f"provider-build-default: {error}")


if __name__ == "__main__":
    main()
