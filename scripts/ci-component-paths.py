#!/usr/bin/env python3
"""Route component CI from a complete local Git diff, without GitHub API limits."""

import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess


COMPONENTS = ("provider", "cluster", "mimo_audio")
COMMON = (
    "Makefile", "mise.toml", ".gitmodules", ".github/workflows/component-changes.yml",
    ".github/workflows/darkbloom-route.yml", ".github/workflows/ci-dev.yml", ".github/workflows/ci-master.yml",
    ".github/workflows/provider-plan.yml", "scripts/ci-tested-tree.py", "scripts/test-ci-tested-tree.py",
    "scripts/ci-component-paths.py", "scripts/test-ci-component-paths.py",
)
PROVIDER = (
    "provider-swift/**", "libs/**", "fixtures/**", "handoff/TUI-wiring.md",
    ".github/workflows/provider-tests.yml", ".github/actions/provider-ci-build/**",
    ".github/actions/provider-ci-products/**", "scripts/ci-test-products.py", "scripts/ci-resource-sampler.py",
    "scripts/provider-ci-cold-retry.sh",
    "scripts/provider-ci-cache.py", "scripts/provider_ci_cache/**",
    "scripts/provider-release-cache.py", "scripts/provider_release_cache/**",
    "scripts/provider-release-swift.sh", "scripts/prepare-provider-release-toolchain.sh",
    "scripts/install-release-cmake.sh", "scripts/prepare-metal-toolchain.py",
    "scripts/fetch-metallib.sh", "scripts/stage-test-metallib.sh",
    "scripts/run-provider-tests.sh", "scripts/run-nested-suite.sh",
    "scripts/run-paged-kernel-tests.sh", "scripts/run-provider-test-watchdog.py",
    "scripts/run-exclusive-native-gpu-test.sh", "scripts/provider-test-shards.py",
    "scripts/provider-test-shard-weights.json",
    "scripts/cluster-test-plan.py", "scripts/cluster-stage-content-inventory.py",
    "scripts/swift_test_lock_retry.py",
    "scripts/prepare-mimo-*-fixtures.py", "scripts/verified_download_cache.py",
    "scripts/verify-*-prompt-parity.sh",
    "scripts/prepare-prompt-fixtures.py", "scripts/test-prepare-prompt-fixtures.py",
    "scripts/verify-prompt-parity.sh", "scripts/test-qwen4-packaged-resources.py",
    "scripts/test-profile-inventory-auth.py", "scripts/test-desktop-api.py", "scripts/install.sh",
    "scripts/test-install-atomic.sh", "scripts/entitlements*.plist",
)


# Inputs of the cluster jobs (Cluster Runtime Tests,
# Cluster GPU Tests, Cluster Focused Checks): the cluster packages and the MLX
# pins they build, the provider sources their runner scripts compile (every
# Cluster, Distributed and NativePair source, and the files the runners name),
# the cluster plan and the shared build recipe. Every cluster input is also a
# provider input.
CLUSTER = (
    "libs/darkbloom-cluster/**", "libs/darkbloom-cluster-worker/**",
    "libs/mlx", "libs/mlx/**", "libs/mlx-swift", "libs/mlx-swift/**", "libs/mlx-swift-lm", "libs/mlx-swift-lm/**",
    "provider-swift/Package.swift", "provider-swift/Package.resolved",
    "provider-swift/Sources/*Cluster*", "provider-swift/Sources/*Distributed*",
    "provider-swift/Sources/*NativePair*",
    "provider-swift/Sources/ProviderCore/Protocol/ProviderExecutionRole.swift",
    "provider-swift/Sources/ProviderCore/Config/ProviderConfigFile.swift",
    "provider-swift/Sources/ProviderCore/Models/StreamingFileDownloadDelegate.swift",
    "provider-swift/Sources/ProviderCoreFoundation/Manifest.swift",
    # The console, diagnostics and placement flow runners compile it beside the placement sources.
    "provider-swift/Sources/ProviderCore/Diagnostics/GLM5NextGPULimitEligibility.swift",
    # The provider-side cluster runners and the fixture one of them reads; the
    # provider unit tests of cluster code run in the provider lane.
    "provider-swift/Tests/Cluster*Checks/**",
    "provider-swift/Tests/ProviderCoreTests/Fixtures/coordinator-wire/cluster_registration_vector.json",
    # The console, diagnostics and placement flow runners compile the build
    # environment; the console runner reads the wiring table.
    "provider-swift/Sources/ProviderBuildEnvironment/**", "handoff/TUI-wiring.md",
    ".github/workflows/provider-tests.yml", ".github/actions/provider-ci-build/**",
    ".github/actions/provider-ci-products/**", "scripts/ci-test-products.py", "scripts/ci-resource-sampler.py",
    "scripts/provider-ci-cold-retry.sh",
    "scripts/provider-ci-cache.py", "scripts/provider_ci_cache/**",
    "scripts/provider-release-cache.py", "scripts/provider_release_cache/**",
    "scripts/provider-release-swift.sh", "scripts/prepare-provider-release-toolchain.sh",
    "scripts/install-release-cmake.sh", "scripts/prepare-metal-toolchain.py",
    "scripts/fetch-metallib.sh", "scripts/stage-test-metallib.sh", "scripts/run-nested-suite.sh",
    "scripts/cluster-test-plan.py", "scripts/cluster-stage-content-inventory.py",
    "scripts/swift_test_lock_retry.py",
)



# Inputs of the MiMo audio gate in the last provider shard, which needs the
# 1.87 GB pinned audio codec: the MiMo, audio and media provider code, the MiMo
# tests, the MLX pins, the fixture scripts (the audio one runs the provider
# fixture generator with --audio-source) and the gate's recipe. Every one is
# also a provider input.
MIMO_AUDIO = (
    "provider-swift/Package.swift", "provider-swift/Package.resolved",
    "provider-swift/Sources/*MiMo*", "provider-swift/Sources/*Audio*", "provider-swift/Sources/*Media*",
    "provider-swift/Tests/ProviderCoreTests/MiMo/*",
    "libs/mlx", "libs/mlx/**", "libs/mlx-swift", "libs/mlx-swift/**", "libs/mlx-swift-lm", "libs/mlx-swift-lm/**",
    ".github/workflows/provider-tests.yml", "scripts/prepare-mimo-audio-fixtures.py",
    "scripts/prepare-mimo-provider-fixtures.py", "scripts/run-nested-suite.sh",
)


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
        selected["provider"] |= matches(path, PROVIDER)
        selected["cluster"] |= matches(path, CLUSTER)
        selected["mimo_audio"] |= matches(path, MIMO_AUDIO)
    return selected


def git(*args):
    return subprocess.check_output(["git", *args])


def revision(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise ValueError("Expected a full Git commit SHA")
    return git("rev-parse", "--verify", value + "^{commit}").decode().strip()


RELEASE_BRANCHES = ("master", "main")


def full_run(event_name, event):
    """Master is the release line: its pushes and the pull requests into it test every component."""
    if event_name == "push":
        return event.get("ref") in tuple(f"refs/heads/{branch}" for branch in RELEASE_BRANCHES)
    if event_name == "pull_request":
        return event["pull_request"]["base"].get("ref") in RELEASE_BRANCHES
    return False


def changed_paths(event_name, event):
    """The changed paths, or None when every component runs."""
    if event_name == "workflow_dispatch" or full_run(event_name, event):
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
    # Pull requests and pushes select alike: a push diffs against the
    # branch's previous commit (`before`); without one, everything runs.
    # Master pushes and pull requests into master select everything.
    selected = dict.fromkeys(COMPONENTS, True) if paths is None else classify(paths)
    output = "".join(f"{name}={str(enabled).lower()}\n" for name, enabled in selected.items())
    if args.output:
        with open(args.output, "a") as destination:
            destination.write(output)
    print(output, end="")


if __name__ == "__main__":
    main()
