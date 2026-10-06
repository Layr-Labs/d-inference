#!/usr/bin/env bash
# Write the coordinator rows of a Go text coverage profile to a scoped profile
# and print their statement total, for example "61.2%".
#
# Usage: scripts/coordinator-statement-coverage.sh PROFILE SCOPED_PROFILE
#
# Fails when the profile has no blocks, has no coordinator rows, or gives no
# statement total. The coverage reports in ci.yml and integration.yml use it.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 PROFILE SCOPED_PROFILE" >&2
  exit 2
fi
profile=$1
scoped=$2

# A profile with only its "mode:" line measured nothing.
if [ "$(wc -l < "$profile")" -le 1 ]; then
  echo "$profile has no coverage data" >&2
  exit 1
fi
head -n 1 "$profile" > "$scoped"
if ! grep '^github.com/eigeninference/d-inference/coordinator/' "$profile" >> "$scoped"; then
  echo "$profile has no coordinator rows" >&2
  exit 1
fi
statements=$(go tool cover -func="$scoped" | awk '$1 == "total:" && $2 == "(statements)" {print $3}')
if ! [[ "$statements" =~ ^[0-9]+(\.[0-9]+)?%$ ]]; then
  echo "Missing statement coverage: '$statements'" >&2
  exit 1
fi
echo "$statements"
