#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAYLOAD="${ROOT}/deploy/datadog/dev-network-dashboard.json"
GCP_PROJECT="${DD_GCP_PROJECT:-${GCP_PROJECT:-sepolia-ai}}"
DASHBOARD_ID="${DD_DASHBOARD_ID:-vij-8u7-xhf}"

fetch_secret() {
  local name="$1"
  if ! command -v gcloud >/dev/null 2>&1; then
    return 1
  fi
  gcloud secrets versions access latest \
    --project="$GCP_PROJECT" \
    --secret="$name" \
    2>/dev/null
}

API_KEY="${DD_API_KEY:-}"
APP_KEY="${DD_APPLICATION_KEY:-${DD_APP_KEY:-${DD_WRITE_KEY:-}}}"
SITE="${DD_SITE:-}"

if [[ -z "$API_KEY" ]]; then
  API_KEY="$(fetch_secret eigeninference-dd-api-key || true)"
fi

if [[ -z "$APP_KEY" ]]; then
  APP_KEY="$(fetch_secret eigeninference-dd-app-key || true)"
fi

if [[ -z "$SITE" ]]; then
  SITE="$(fetch_secret eigeninference-dd-site || true)"
fi

SITE="${SITE:-datadoghq.com}"

if [[ -z "$API_KEY" ]]; then
  echo "DD_API_KEY is required" >&2
  exit 1
fi

if [[ -z "$APP_KEY" ]]; then
  echo "DD_APPLICATION_KEY, DD_APP_KEY, or DD_WRITE_KEY is required for dashboard writes" >&2
  exit 1
fi

response="$(mktemp)"
validation_response="$(mktemp)"
trap 'rm -f "$response" "$validation_response"' EXIT

method="POST"
url="https://api.${SITE}/api/v1/dashboard"
action="Created"
if [[ -n "$DASHBOARD_ID" ]]; then
  method="PUT"
  url="${url}/${DASHBOARD_ID}"
  action="Updated"
fi

code="$(curl -sS -o "$response" -w '%{http_code}' \
  -X "$method" "$url" \
  -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${API_KEY}" \
  -H "DD-APPLICATION-KEY: ${APP_KEY}" \
  --data-binary "@${PAYLOAD}")"

python3 - "$response" "$code" <<'PY'
import json
import sys

path, code = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    body = f.read()

if code not in {"200", "201"}:
    print(f"Datadog dashboard create failed: HTTP {code}", file=sys.stderr)
    print(body, file=sys.stderr)
    sys.exit(1)

payload = json.loads(body)
dashboard_id = payload.get("id")
url = payload.get("url")
action = "Updated" if code == "200" else "Created"

print(f"{action} Datadog dashboard: {dashboard_id}")
if url:
    print(url)
PY

validate_logs_query() {
  local label="$1"
  local query="$2"
  local body
  body="$(python3 - "$query" <<'PY'
import json
import sys

query = sys.argv[1]
print(json.dumps({
    "filter": {
        "from": "now-4h",
        "to": "now",
        "query": query,
    },
    "page": {"limit": 1},
    "sort": "-timestamp",
}))
PY
)"

  local status
  status="$(curl -sS -o "$validation_response" -w '%{http_code}' \
    -X POST "https://api.${SITE}/api/v2/logs/events/search" \
    -H "Content-Type: application/json" \
    -H "DD-API-KEY: ${API_KEY}" \
    -H "DD-APPLICATION-KEY: ${APP_KEY}" \
    --data-binary "$body")"

  if [[ "$status" != "200" ]]; then
    echo "Validation query failed for ${label}: HTTP ${status}" >&2
    cat "$validation_response" >&2
    return 1
  fi

  python3 - "$validation_response" "$label" <<'PY'
import json
import sys

path, label = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)

events = payload.get("data") or []
latest = "none"
if events:
    latest = events[0].get("attributes", {}).get("timestamp", "unknown")

print(f"Validation {label}: events={len(events)} latest={latest}")
PY
}

validate_logs_query "all dev logs" "env:development service:d-inference-coordinator"
validate_logs_query "provider telemetry" "env:development service:d-inference-coordinator source:provider"
validate_logs_query "coordinator logs" "env:development service:d-inference-coordinator source:coordinator"
