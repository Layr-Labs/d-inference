#!/bin/bash
set -u -o pipefail

platform=${1:?usage: run-dev-deploy-safety-ci.sh <platform>}
fixture_root=$(mktemp -d "$RUNNER_TEMP/dev-deploy-fixtures.XXXXXX") || exit 1
test_log="$RUNNER_TEMP/dev-deploy-tests.log"
inventory="$RUNNER_TEMP/dev-deploy-fixture-inventory.txt"

if ! initial_status=$(git status --porcelain --untracked-files=all); then
    echo "Could not inspect the source tree before tests" >&2
    exit 1
fi
if [ -n "$initial_status" ]; then
    echo "Source tree is not clean before tests:" >&2
    printf '%s\n' "$initial_status" >&2
    exit 1
fi

set +e
TMPDIR="$fixture_root" PYTHONDONTWRITEBYTECODE=1 \
    python3 -B scripts/test-dev-deploy.py -v 2>&1 | tee "$test_log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
suite_rc=${pipeline_status[0]}
tee_rc=${pipeline_status[1]}

containment_rc=0
if ! find "$fixture_root" -mindepth 1 -maxdepth 3 -print > "$inventory"; then
    echo "Could not inspect temporary fixture containment" >&2
    containment_rc=1
elif [ -s "$inventory" ]; then
    echo "Temporary fixture residue:" >&2
    sed 's/^/  /' "$inventory" >&2
    containment_rc=1
fi
source_rc=0
if ! source_status=$(git status --porcelain --untracked-files=all); then
    echo "Could not inspect the source tree after tests" >&2
    source_rc=1
elif [ -n "$source_status" ]; then
    echo "Source tree changed during tests:" >&2
    printf '%s\n' "$source_status" >&2
    source_rc=1
fi

{
    echo "### Dev deploy safety — $platform"
    echo '```text'
    if [ -f "$test_log" ]; then
        grep -E ' skipped |^Ran |^OK|^FAILED' "$test_log" || true
    else
        echo "test log unavailable"
    fi
    echo '```'
    echo "Fixture containment: $([ "$containment_rc" -eq 0 ] && echo clean || echo failed)"
    echo "Source tree (including untracked files): $([ "$source_rc" -eq 0 ] && echo clean || echo failed)"
    echo "Test log capture: $([ "$tee_rc" -eq 0 ] && echo complete || echo failed)"
} >> "$GITHUB_STEP_SUMMARY"

[ "$suite_rc" -eq 0 ] && [ "$tee_rc" -eq 0 ] &&
    [ "$containment_rc" -eq 0 ] && [ "$source_rc" -eq 0 ]
