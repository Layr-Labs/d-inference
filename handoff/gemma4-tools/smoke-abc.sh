#!/bin/bash
# usage: smoke-abc.sh KEY CUT
# First run of a new adapter on this Mac: both ranks' stage loads at one cut,
# the staged reference twice (the oracle), then two real workers over the local
# test socket once, compared with the oracle. Stops at the first failure.
set -uo pipefail
here="$(dirname "$0")"
SMOKE_ONLY=1 "$here/ladder1.sh" "$1" "$2" "" "$2" || exit $?
ONLY_SMOKE=1 "$here/ladder2.sh" "$1" "$2" "$2"
