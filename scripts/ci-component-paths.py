#!/usr/bin/env python3
"""Route component CI from a complete local Git diff, without GitHub API limits."""

import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess


COMPONENTS = ("coordinator", "provider", "sidecar", "console", "integration", "benchmark")
COMMON = (
    "Makefile", "mise.toml", ".gitmodules", ".github/workflows/component-changes.yml",
    "scripts/ci-component-paths.py", "scripts/test-ci-component-paths.py",
)
PROVIDER = (
    "provider-swift/**", "libs/**", ".github/actions/provider-ci-build/**",
    "scripts/provider-ci-cache.py", "scripts/provider_ci_cache/**",
    "scripts/provider-release-cache.py", "scripts/provider_release_cache/**",
    "scripts/provider-release-swift.sh", "scripts/prepare-provider-release-toolchain.sh",
    "scripts/install-release-*.sh", "scripts/prepare-metal-toolchain.py",
    "scripts/fetch-metallib.sh", "scripts/stage-test-metallib.sh",
    "scripts/run-provider-tests.sh", "scripts/run-nested-suite.sh",
    "scripts/run-paged-kernel-tests.sh", "scripts/run-provider-test-watchdog.py",
    "scripts/run-exclusive-native-gpu-test.sh",
    "scripts/prepare-mimo-*-fixtures.py", "scripts/verify-*-prompt-parity.sh",
    "scripts/verify-prompt-parity.sh", "scripts/test-qwen4-packaged-resources.py",
    "scripts/test-profile-inventory-auth.py", "scripts/install.sh",
    "scripts/test-install-atomic.sh", "scripts/entitlements*.plist",
)
SHARED = (
    "fixtures/**", "coordinator/protocol/**", "coordinator/tests/protocol/**",
    "coordinator/promptsidecar/**", "coordinator/promptcontract/**",
    "coordinator/internal/promptcontract/**", "coordinator/cmd/promptfixtureinput/**",
    "coordinator/internal/promptproof/**", "coordinator/mediawork/**",
    "coordinator/cmd/promptsidecarloadproof/**", "go.mod", "go.sum",
)
GO = (
    "coordinator/**", "e2e/**", "go.mod", "go.sum", ".golangci.yml",
    "scripts/run-coordinator-tests.py", "scripts/coordinator_tests/**",
    "scripts/test-coordinator-tests.py", "scripts/coordinator-tests.sh",
    "scripts/sync-install-embed.sh", "scripts/install.sh", "fixtures/**",
    "scripts/verify-prompt-parity.sh", "scripts/verify-nemotron-prompt-parity.sh",
    "scripts/verify-prompt-sidecar-linux.sh",
    "provider-swift/Sources/ProviderCore/ProviderCore.swift",
)
SIDECAR = SHARED + (
    "coordinator/Dockerfile", ".dockerignore", "scripts/install-release-rust.sh",
    "scripts/prepare-mimo-prompt-fixtures.py", "scripts/test-prepare-mimo-prompt-fixtures.py",
    "scripts/verify-prompt-sidecar-linux.sh", "scripts/verify-prompt-parity.sh",
    "scripts/verify-nemotron-prompt-parity.sh",
    "provider-swift/Tests/ProviderCoreTests/Fixtures/nemotron-prompt-edge-corpus.json",
    "provider-swift/Tests/ProviderCoreTests/Fixtures/nemotron-reference-corpus.json",
)
E2E_TOOLING = (
    "scripts/setup-macos-homebrew.sh", "scripts/install-macos-github-cli.sh",
    "scripts/run-e2e*.sh",
)
CONSOLE = ("console-ui/**", "coordinator/protocol/telemetry.go")


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
        coordinator = matches(path, GO) or path.endswith(".go")
        sidecar = matches(path, SIDECAR)
        selected["provider"] |= ci or provider
        selected["coordinator"] |= ci or coordinator
        selected["sidecar"] |= ci or sidecar
        selected["console"] |= ci or matches(path, CONSOLE)
        e2e = provider or coordinator or sidecar or matches(path, E2E_TOOLING)
        selected["integration"] |= e2e or path in (
            ".github/workflows/integration.yml", "scripts/test-integration-ci-workflow.py",
        )
        selected["benchmark"] |= e2e or path == ".github/workflows/benchmarks.yml"
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
    # --no-renames reports a move as delete + add, preserving BOTH dependency
    # paths. NUL delimiters also preserve whitespace/newlines in filenames.
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
    # Default-branch pushes retain full coverage, but still validate the push
    # diff so broken detection cannot silently claim an intentional skip.
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
