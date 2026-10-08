#!/bin/bash
# DevNet suite: checks the deployed dev coordinator through its public
# endpoints. .github/workflows/devnet-suite.yml runs it; a human can run it too.
#
# Usage:
#   EXPECTED_COMMIT=<40-hex commit> [COORD=https://<host>] [API_KEY=<dev key>]
#       [MASTER_REF=origin/master] scripts/devnet-suite.sh
#
# COORD defaults to https://<DOMAIN of deploy/gcp/dev/env-overrides>. The
# checkout must have the history of MASTER_REF.
# Checks:
#   1. /health: status ok and build_commit = EXPECTED_COMMIT. Hard.
#   2. EXPECTED_COMMIT is on MASTER_REF. Hard. The workflow takes
#      EXPECTED_COMMIT from /health, so this is the check that can fail when
#      dev runs a commit that is not on master.
#   3. The number of MASTER_REF first-parent commits after EXPECTED_COMMIT.
#      Report only: a paused deploy lags on purpose.
#   4. /v1/stats: active_providers >= 1. Report only.
#   5. scripts/smoke-dev.sh with the authenticated chat test, only when API_KEY
#      is set. Hard when it runs. smoke-dev.sh also fails when no provider is
#      attached.
# Writes a Markdown report to GITHUB_STEP_SUMMARY when it is set, else to
# stdout. Exit 1 when a hard check fails, 2 on a usage error.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV_DOMAIN=$(awk -F= '$1 == "DOMAIN" { print $2; exit }' "$ROOT/deploy/gcp/dev/env-overrides")
COORD=${COORD:-https://$DEV_DOMAIN}
EXPECTED_COMMIT=${EXPECTED_COMMIT:-}
API_KEY=${API_KEY:-}
MASTER_REF=${MASTER_REF:-origin/master}
REPORT=${GITHUB_STEP_SUMMARY:-/dev/stdout}

[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: EXPECTED_COMMIT=<40-hex commit> $0" >&2; exit 2; }

start=$(date +%s)
rows=()
hard_fail=0
add_row() { rows+=("| $1 | $2 | $3 |"); }

label="/health status ok, build_commit is the tested commit"
body=$(curl -fsS --max-time 10 "$COORD/health" 2>/dev/null) || body=""
if jq -e --arg c "$EXPECTED_COMMIT" '.status == "ok" and .build_commit == $c' <<< "$body" >/dev/null 2>&1; then
    add_row "$label" hard pass
else
    add_row "$label" hard fail
    hard_fail=1
    echo "::error::/health does not report $EXPECTED_COMMIT: ${body:-no answer}"
fi

label="the tested commit is on $MASTER_REF"
if git -C "$ROOT" merge-base --is-ancestor "$EXPECTED_COMMIT" "$MASTER_REF" 2>/dev/null; then
    add_row "$label" hard pass
    behind=$(git -C "$ROOT" rev-list --first-parent --count "$EXPECTED_COMMIT..$MASTER_REF" 2>/dev/null) || behind=""
    add_row "master commits after the tested commit (now ${behind:-unknown})" report "$([[ "$behind" =~ ^[0-9]+$ ]] && echo pass || echo fail)"
else
    add_row "$label" hard fail
    hard_fail=1
    echo "::error::$EXPECTED_COMMIT is not on $MASTER_REF, or the checkout has no history of $MASTER_REF"
fi

providers=$(curl -fsS --max-time 10 "$COORD/v1/stats" 2>/dev/null | jq -r '.active_providers // 0' 2>/dev/null) || providers=""
providers=${providers:-unknown}
if [[ "$providers" =~ ^[0-9]+$ ]] && [ "$providers" -ge 1 ]; then
    add_row "active_providers >= 1 (now $providers)" report pass
else
    add_row "active_providers >= 1 (now $providers)" report fail
    echo "::warning::no attached provider (active_providers=$providers)"
fi

label="scripts/smoke-dev.sh with the authenticated chat test"
if [ -z "$API_KEY" ]; then
    add_row "$label" hard skipped
    echo "::notice::DEVNET_SMOKE_API_KEY is not set; the authenticated chat test is skipped"
elif COORD="$COORD" API_KEY="$API_KEY" "$ROOT/scripts/smoke-dev.sh"; then
    add_row "$label" hard pass
else
    add_row "$label" hard fail
    hard_fail=1
fi

result=pass
[ "$hard_fail" = 0 ] || result=fail
{
    echo "### DevNet suite: $result, commit \`$EXPECTED_COMMIT\`"
    echo
    echo "| Check | Kind | Result |"
    echo "|---|---|---|"
    printf '%s\n' "${rows[@]}"
    echo
    echo "Coordinator: $COORD. Duration: $(( $(date +%s) - start )) s."
} >> "$REPORT"
echo "RESULT $result $EXPECTED_COMMIT"
[ "$hard_fail" = 0 ]
