#!/bin/bash
# check-fixed-stack.sh BINARY...
#
# Every executable Darkbloom.app ships links a fixed 8 MiB main-thread stack
# (LC_MAIN stacksize; 8 MiB is launchd's default limit), so the stack limit a
# process is started with cannot stop it before `main` applies its start-up
# hardening (ProcessStartupHardening). The product builds pass
# `-Xlinker -stack_size -Xlinker 0x800000` (.github/actions/provider-release-build,
# provider-signing-validation.yml, libs/darkbloom-cluster-worker/build-native-worker.sh).
# It is a link option of those builds, not a Package.swift setting: a test bundle
# that links an executable target's code cannot carry it.
#
# Exits 1 naming the first BINARY whose LC_MAIN stack size is not 8 MiB.
set -euo pipefail
if [[ $# == 0 ]]; then
  echo 'usage: check-fixed-stack.sh BINARY...' >&2
  exit 2
fi
expected=8388608
for binary in "$@"; do
  # grep reads all of otool's output (no early exit), so the pipeline status is grep's.
  main="$(/usr/bin/otool -l "$binary" | grep -A3 'cmd LC_MAIN' || true)"
  if [[ "$main" != *"stacksize $expected"* ]]; then
    echo "$binary does not link the fixed main-thread stack (LC_MAIN stacksize $expected): ${main:-no LC_MAIN}" >&2
    exit 1
  fi
done
