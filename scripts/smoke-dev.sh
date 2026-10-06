#!/bin/bash
# End-to-end smoke test for the dev coordinator. Intended to run post-deploy
# (Cloud Build step) and on a cron (GH Actions). Any failure non-zero-exits
# so the calling job can alert.
#
# Usage:
#   [COORD=https://<host>] [MODEL=<model id>] API_KEY=$DEV_API_KEY scripts/smoke-dev.sh
#
# COORD defaults to https://<DOMAIN of deploy/gcp/dev/env-overrides>. MODEL
# defaults to Qwen3.5-9B; only the authenticated chat test uses it.
# API_KEY must be a test account's Darkbloom API key with non-zero credits.
# No prod API keys. No real prompts — all test inputs are synthetic.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV_DOMAIN=$(awk -F= '$1 == "DOMAIN" { print substr($0, index($0, "=") + 1); exit }' "$ROOT/deploy/gcp/dev/env-overrides")
COORD="${COORD:-https://$DEV_DOMAIN}"
MODEL="${MODEL:-Qwen3.5-9B}"
API_KEY="${API_KEY:-}"
FAIL=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\n--- %s ---\n' "$*"; }

require() {
  local name="$1"; local val="$2"
  if [ -z "$val" ]; then
    red "missing $name — set it and retry"
    exit 2
  fi
}

fail() {
  red "FAIL: $*"
  FAIL=$((FAIL+1))
}

step "health"
if curl -fsS "$COORD/health" >/dev/null; then
  green "health OK"
else
  fail "health endpoint not responding"
fi

step "stats (public)"
PROVIDER_COUNT=$(curl -fsS "$COORD/v1/stats" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(int(d.get("active_providers", d.get("providers_online", 0))))' 2>/dev/null || echo 0)
if [ "$PROVIDER_COUNT" -gt 0 ]; then
  green "providers online: $PROVIDER_COUNT"
else
  fail "no providers visible in /v1/stats (dev fleet offline?)"
fi

step "model catalog"
MODEL_COUNT=$(curl -fsS "$COORD/v1/models/catalog" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("models", d if isinstance(d,list) else [])))' 2>/dev/null || echo 0)
if [ "$MODEL_COUNT" -gt 0 ]; then
  green "catalog has $MODEL_COUNT models"
else
  fail "model catalog empty"
fi

step "install.sh templating"
if curl -fsS "$COORD/install.sh" | grep -Fq "$COORD"; then
  green "install.sh references dev coordinator"
else
  fail "install.sh does not reference dev coordinator (templating broken?)"
fi

# Authenticated tests only run if an API key is supplied.
if [ -n "$API_KEY" ]; then
  step "chat completions (authenticated)"
  smoke_result=$(mktemp -t darkbloom-smoke.XXXXXX)
  trap 'rm -f "$smoke_result"' EXIT
  HTTP_CODE=$(curl -sS -o "$smoke_result" -w '%{http_code}' \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":false}" \
    "$COORD/v1/chat/completions" || echo 000)
  if [ "$HTTP_CODE" = "200" ]; then
    green "chat OK"
  else
    fail "chat returned $HTTP_CODE: $(head -c 400 "$smoke_result")"
  fi
else
  echo "(skipping authenticated tests — set API_KEY to enable)"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  red "$FAIL check(s) failed"
  exit 1
fi
green "all checks passed"
