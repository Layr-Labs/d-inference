#!/bin/bash
# The one forced exit (ProcessForcedExit) and the deadline thread that takes it
# (ProcessDeadline), from the runtime's actual sources, compiled without MLX:
# release before exit, the dead-man bound, the first claim winning, SIGTERM,
# SIGHUP and SIGALRM routed, an inherited SIGINT ignore kept. Each case is a
# child process that really exits; no model, no GPU, no network. About 10 s.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
support="$task_root/Sources/DarkbloomClusterRuntime/Support"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-exit-checks.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  "$support/ProcessForcedExit.swift" "$support/ProcessDeadline.swift" "$support/ClusterRuntimeError.swift" \
  "$task_root/Tests/ExitChecks/ExitCheck.swift" -o "$task_build/exit-check"
"$task_build/exit-check"
