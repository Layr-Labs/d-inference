#!/bin/bash
# DevNet suite: checks the deployed dev coordinator through its public
# endpoints. .github/workflows/devnet-suite.yml runs it; a human can run it too.
#
# Usage:
#   EXPECTED_COMMIT=<40-hex commit> [COORD=https://<host>] [API_KEY=<dev key>] scripts/devnet-suite.sh
#
# COORD defaults to https://<DOMAIN of deploy/gcp/dev/env-overrides>.
# Checks:
#   1. /health: status ok and build_commit = EXPECTED_COMMIT. Hard.
#   2. /v1/stats: active_providers >= 1. Report only.
#   3. scripts/smoke-dev.sh with the authenticated chat test, only when API_KEY
#      is set. Hard when it runs. The chat test needs an attached provider.
# Writes a Markdown report to GITHUB_STEP_SUMMARY when it is set, else to
# stdout. Exit 1 when a hard check fails, 2 on a usage error.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV_DOMAIN=$(awk -F= '$1 == "DOMAIN" { print $2; exit }' "$ROOT/deploy/gcp/dev/env-overrides")
COORD=${COORD:-https://$DEV_DOMAIN}
EXPECTED_COMMIT=${EXPECTED_COMMIT:-}
API_KEY=${API_KEY:-}
REPORT=${GITHUB_STEP_SUMMARY:-/dev/stdout}

[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: EXPECTED_COMMIT=<40-hex commit> $0" >&2; exit 2; }

start=$(date +%s)
rows=()
hard_fail=0
check() { rows+=("| $1 | $2 | $3 |"); }

body=$(curl -fsS --max-time 10 "$COORD/health" 2>/dev/null) || body=""
if [ -n "$body" ] && jq -e --arg c "$EXPECTED_COMMIT" '.status == "ok" and .build_commit == $c' <<< "$body" >/dev/null 2>&1; then
    check "/health status ok, build_commit is the tested commit" hard pass
else
    check "/health status ok, build_commit is the tested commit" hard fail
    hard_fail=1
    echo "::error::/health does not report $EXPECTED_COMMIT: ${body:-no answer}"
fi

providers=$(curl -fsS --max-time 10 "$COORD/v1/stats" 2>/dev/null | jq -r '.active_providers // 0' 2>/dev/null) || providers=unknown
if [[ "$providers" =~ ^[0-9]+$ ]] && [ "$providers" -ge 1 ]; then
    check "active_providers >= 1 (now $providers)" report pass
else
    check "active_providers >= 1 (now ${providers:-unknown})" report fail
    echo "::warning::no attached provider (active_providers=${providers:-unknown})"
fi

if [ -z "$API_KEY" ]; then
    check "scripts/smoke-dev.sh with the authenticated chat test" hard skipped
    echo "::notice::DEVNET_SMOKE_API_KEY is not set; the authenticated chat test is skipped"
elif COORD="$COORD" API_KEY="$API_KEY" "$ROOT/scripts/smoke-dev.sh"; then
    check "scripts/smoke-dev.sh with the authenticated chat test" hard pass
else
    check "scripts/smoke-dev.sh with the authenticated chat test" hard fail
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
