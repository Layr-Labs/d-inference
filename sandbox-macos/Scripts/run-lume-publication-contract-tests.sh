#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${DARKBLOOM_LUME_PYTHON:-$(command -v python3)}"
TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/darkbloom-lume-publication-tests.XXXXXX")"

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    /bin/rm -f -- "$TEST_LOG"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/bash "$SCRIPT_DIR/test-lume-runtime-publication.sh" 2>&1 \
    | tee "$TEST_LOG"

EXPECTED_CASES=(
    sealed-tree
    no-overwrite
    hardlink-rejection
    post-publication-retention
    identity-bound-quarantine
    quarantine-replacement
    unsafe-path-rejection
)
case "$(uname -s)" in
    Darwin)
        EXPECTED_CASES+=(descendant-acl-rejection acl-isolation)
        ;;
    Linux)
        ;;
    *)
        echo "unsupported publication contract platform" >&2
        exit 1
        ;;
esac

"$PYTHON" - "$TEST_LOG" "${EXPECTED_CASES[@]}" <<'PY'
from collections import Counter
import sys

log_path, *expected = sys.argv[1:]
with open(log_path, encoding="utf-8") as source:
    lines = [line.rstrip("\n") for line in source]

pass_prefix = "lume_publication_contract_pass="
summary_prefix = "lume_publication_contract_tests="
passes = [line[len(pass_prefix):] for line in lines if line.startswith(pass_prefix)]
summaries = [line for line in lines if line.startswith(summary_prefix)]
counts = Counter(passes)
invalid = sorted(name for name, count in counts.items() if name not in expected or count != 1)
missing = sorted(name for name in expected if counts[name] != 1)
expected_summary = f"{summary_prefix}{len(expected)}"
if len(set(expected)) != len(expected) or invalid or missing or summaries != [expected_summary]:
    raise SystemExit(
        "publication contract tripwire mismatch: "
        f"expected={expected!r} passes={passes!r} summaries={summaries!r}"
    )
PY

echo "lume_publication_contract_tripwire=exact:${#EXPECTED_CASES[@]}"
