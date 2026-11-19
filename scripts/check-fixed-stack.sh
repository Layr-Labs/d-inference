#!/bin/bash
# check-fixed-stack.sh BINARY...
#
# Every executable Darkbloom.app ships links a fixed 8 MiB main-thread stack
# (LC_MAIN stacksize; 8 MiB is launchd's default limit), independent of the
# stack limit it is started with. The product builds pass
# `-Xlinker -stack_size -Xlinker 0x800000` (.github/actions/provider-release-build,
# provider-signing-validation.yml, libs/darkbloom-cluster-worker/build-native-worker.sh).
# It is a link option of those builds, not a Package.swift setting: a test bundle
# that links an executable target's code cannot carry it.
#
# Exits 1 naming the first BINARY that has no LC_MAIN, or an LC_MAIN (any
# slice of a universal file) whose stack size is not exactly 8 MiB.
set -euo pipefail
if [[ $# == 0 ]]; then
  echo 'usage: check-fixed-stack.sh BINARY...' >&2
  exit 2
fi
expected=8388608
for binary in "$@"; do
  # Every LC_MAIN's stacksize field, one per line (awk reads all of otool's output).
  sizes="$(/usr/bin/otool -l "$binary" | awk '$1 == "cmd" { main = ($2 == "LC_MAIN") } main && $1 == "stacksize" { print $2 }')"
  if [[ -z "$sizes" ]] || grep -qvx "$expected" <<<"$sizes"; then
    echo "$binary does not link the fixed main-thread stack (LC_MAIN stacksize $expected): ${sizes:-no LC_MAIN}" >&2
    exit 1
  fi
done
