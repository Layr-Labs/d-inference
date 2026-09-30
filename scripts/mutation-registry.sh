#!/usr/bin/env bash
# Report-only mutation test of the registry routing and scheduler files.
# Run it with `make mutation-registry`. See docs/developer/test.md.
#
# The score never fails this script. It fails only when setup breaks or the
# run uses its whole time budget and writes no report.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${MUTATION_OUT:-artifacts/mutation}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version="${GREMLINS_VERSION:-v0.6.0}"
budget="${MUTATION_BUDGET:-240m}"
workers="${MUTATION_WORKERS:-0}"
coefficient="${MUTATION_TIMEOUT_COEFFICIENT:-5}"
pkg="$root/coordinator/registry"

# The tool is pinned and installed outside the main module, so it does not
# enter go.mod or go.sum.
GOBIN="$out/bin" go install "github.com/go-gremlins/gremlins/cmd/gremlins@$version"

# Mutate only these files. Exclude every other file and all subpackages.
excludes=(-E '/')
for file in "$pkg"/*.go; do
    name="$(basename "$file")"
    case "$name" in
        *_test.go | scheduler.go | candidate_selection.go | first_content_*.go) ;;
        *) excludes+=(-E "^${name//./\\.}\$") ;;
    esac
done

# Each mutant compiles a new registry package, and each build adds tens of MB
# to the Go build cache. Use a private cache for the run, and delete entries
# that the run made more than 5 minutes ago. They are never used again.
cache="$out/gocache"
rm -rf "$cache" "$out/registry.json" "$out/registry.txt" "$out/registry-summary.md"
mkdir -p "$cache"
trimmer=""
trap '[ -z "$trimmer" ] || kill "$trimmer" 2>/dev/null || true; rm -rf "$cache"' EXIT
export GOCACHE="$cache"
(cd "$root" && go test -count=1 -run '^$' ./coordinator/registry/...)
touch "$cache/.warm"
(
    while sleep 60; do
        find "$cache" -type f -newer "$cache/.warm" -mmin +5 -delete 2>/dev/null || true
    done
) &
trimmer=$!

status=0
timeout "$budget" "$out/bin/gremlins" unleash \
    --workers "$workers" \
    --timeout-coefficient "$coefficient" \
    --output "$out/registry.json" \
    "${excludes[@]}" \
    "$pkg" 2>&1 | tee "$out/registry.txt" || status=$?
if [ "$status" -ne 0 ]; then
    echo "gremlins exited with status $status" >&2
fi

python3 "$root/scripts/mutation-summary.py" "$out/registry.json" > "$out/registry-summary.md"
cat "$out/registry-summary.md"
