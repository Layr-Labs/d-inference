#!/usr/bin/env python3
"""Route component CI from a complete local Git diff, without GitHub API limits."""

import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess


COMPONENTS = ("provider",)
COMMON = (
    "Makefile", "mise.toml", ".gitmodules", ".github/workflows/component-changes.yml",
    "scripts/ci-component-paths.py", "scripts/test-ci-component-paths.py",
)
PROVIDER = (
    "provider-swift/**", "libs/**", ".github/actions/provider-ci-build/**",
    "scripts/provider-ci-cache.py", "scripts/provider_ci_cache/**",
    "scripts/provider-release-cache.py", "scripts/provider_release_cache/**",
    "scripts/provider-release-swift.sh", "scripts/prepare-provider-release-toolchain.sh",
    "scripts/install-release-cmake.sh", "scripts/prepare-metal-toolchain.py",
    "scripts/fetch-metallib.sh", "scripts/stage-test-metallib.sh",
    "scripts/run-provider-tests.sh", "scripts/run-nested-suite.sh",
    "scripts/run-paged-kernel-tests.sh", "scripts/run-provider-test-watchdog.py",
    "scripts/run-exclusive-native-gpu-test.sh",
    "scripts/prepare-mimo-*-fixtures.py", "scripts/verify-*-prompt-parity.sh",
    "scripts/prepare-prompt-fixtures.py", "scripts/test-prepare-prompt-fixtures.py",
    "scripts/verify-prompt-parity.sh", "scripts/test-qwen4-packaged-resources.py",
    "scripts/test-profile-inventory-auth.py", "scripts/install.sh",
    "scripts/test-install-atomic.sh", "scripts/entitlements*.plist",
)
SHARED = ("fixtures/**",)


def matches(path, patterns):
    return any(fnmatchcase(path, pattern) for pattern in patterns)


def classify(paths):
    selected = {component: False for component in COMPONENTS}
    for path in paths:
        # Instructions and documentation are not executable dependencies, even
        # when they live alongside component sources.
        if path.startswith("docs/") or path.endswith("/AGENTS.md") or path == "AGENTS.md":
            continue
        if matches(path, COMMON):
            return dict.fromkeys(COMPONENTS, True)
        ci = path == ".github/workflows/ci.yml"
        provider = matches(path, PROVIDER + SHARED)
        selected["provider"] |= ci or provider
    return selected


def git(*args):
    return subprocess.check_output(["git", *args])


def revision(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise ValueError("Expected a full Git commit SHA")
    return git("rev-parse", "--verify", value + "^{commit}").decode().strip()


def changed_paths(event_name, event):
    if event_name == "workflow_dispatch":
        return None
    if event_name == "pull_request":
        base = revision(event["pull_request"]["base"]["sha"])
        head = revision(event["pull_request"]["head"]["sha"])
        base = git("merge-base", base, head).decode().strip()
    elif event_name == "push":
        head = revision(event["after"])
        before = event["before"]
        if before == "0" * 40:
            return None  # New branch: no trustworthy previous snapshot; run all.
        base = revision(before)
    else:
        raise ValueError(f"Unsupported event: {event_name}")
    # Include both ends of moves and preserve whitespace/newlines in filenames.
    diff = git("diff", "--name-only", "--no-renames", "-z", base, head, "--")
    return [os.fsdecode(path) for path in diff.split(b"\0") if path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME"))
    parser.add_argument("--event-path", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args()
    event = json.loads(Path(args.event_path).read_text())
    paths = changed_paths(args.event_name, event)
    # Default-branch pushes retain full coverage after validating the diff.
    full = paths is None or (args.event_name == "push" and event.get("ref") in
                             ("refs/heads/master", "refs/heads/main"))
    selected = dict.fromkeys(COMPONENTS, True) if full else classify(paths)
    output = "".join(f"{name}={str(enabled).lower()}\n" for name, enabled in selected.items())
    if args.output:
        with open(args.output, "a") as destination:
            destination.write(output)
    print(output, end="")


if __name__ == "__main__":
    main()
