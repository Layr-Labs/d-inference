#!/usr/bin/env bash
# Create or update a Datadog monitor from a JSON definition under
# deploy/datadog/monitors/. Idempotent: an existing monitor with the same name
# and the managed-by:deploy/datadog tag is updated in place.
#
#   deploy/datadog/apply-monitor.sh [--validate] [monitor.json]
#
# DD_MONITOR_NOTIFY   handle(s) substituted for __NOTIFY__ in the message,
#                     e.g. "@slack-darkbloom-oncall @pagerduty-coordinator".
#                     Empty leaves the monitor without a notification target.
# DD_MONITOR_ID       skip the lookup and update this monitor id.
# Credentials resolve exactly as in apply-dev-dashboard.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATE_ONLY=0
if [[ "${1:-}" == "--validate" ]]; then
  VALIDATE_ONLY=1
  shift
fi
PAYLOAD="${1:-${ROOT}/deploy/datadog/monitors/cache-refresh-failed.json}"
GCP_PROJECT="${DD_GCP_PROJECT:-${GCP_PROJECT:-sepolia-ai}}"

fetch_secret() {
  local name="$1"
  command -v gcloud >/dev/null 2>&1 || return 1
  gcloud secrets versions access latest --project="$GCP_PROJECT" --secret="$name" 2>/dev/null
}

API_KEY="${DD_API_KEY:-}"
APP_KEY="${DD_APPLICATION_KEY:-${DD_APP_KEY:-${DD_WRITE_KEY:-}}}"
SITE="${DD_SITE:-}"
[[ -n "$API_KEY" ]] || API_KEY="$(fetch_secret eigeninference-dd-api-key || true)"
[[ -n "$APP_KEY" ]] || APP_KEY="$(fetch_secret eigeninference-dd-app-key || true)"
[[ -n "$SITE" ]] || SITE="$(fetch_secret eigeninference-dd-site || true)"
SITE="${SITE:-datadoghq.com}"
if [[ -z "$API_KEY" ]]; then echo "DD_API_KEY is required" >&2; exit 1; fi
if [[ -z "$APP_KEY" ]]; then echo "DD_APPLICATION_KEY, DD_APP_KEY, or DD_WRITE_KEY is required for monitor writes" >&2; exit 1; fi

rendered="$(mktemp)"
response="$(mktemp)"
trap 'rm -f "$rendered" "$response"' EXIT

# Substitute the notification handle; drop the placeholder line when unset.
python3 - "$PAYLOAD" "${DD_MONITOR_NOTIFY:-}" > "$rendered" <<'PY'
import json, sys
path, notify = sys.argv[1], sys.argv[2].strip()
monitor = json.load(open(path, encoding="utf-8"))
lines = [notify if line == "__NOTIFY__" else line for line in monitor["message"].split("\n")]
monitor["message"] = "\n".join(line for line in lines if line != "")
print(json.dumps(monitor))
PY
NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$rendered")"

dd() {
  local method="$1" path="$2"; shift 2
  curl -sS -o "$response" -w '%{http_code}' -X "$method" "https://api.${SITE}/api/v1/${path}" \
    -H "Content-Type: application/json" -H "DD-API-KEY: ${API_KEY}" -H "DD-APPLICATION-KEY: ${APP_KEY}" "$@"
}

code="$(dd POST monitor/validate --data-binary "@${rendered}")"
if [[ "$code" != "200" ]]; then
  echo "Datadog monitor validation failed: HTTP ${code}" >&2; cat "$response" >&2; exit 1
fi
echo "Validated monitor definition: ${NAME}"
if [[ "$VALIDATE_ONLY" == "1" ]]; then exit 0; fi

MONITOR_ID="${DD_MONITOR_ID:-}"
if [[ -z "$MONITOR_ID" ]]; then
  code="$(dd GET 'monitor?monitor_tags=managed-by:deploy/datadog')"
  if [[ "$code" != "200" ]]; then
    echo "Datadog monitor lookup failed: HTTP ${code}" >&2; cat "$response" >&2; exit 1
  fi
  MONITOR_ID="$(python3 -c '
import json, sys
name = sys.argv[2]
ids = [str(m["id"]) for m in json.load(open(sys.argv[1])) if m.get("name") == name]
print(ids[0] if ids else "")' "$response" "$NAME")"
fi

if [[ -n "$MONITOR_ID" ]]; then
  code="$(dd PUT "monitor/${MONITOR_ID}" --data-binary "@${rendered}")"; action="Updated"
else
  code="$(dd POST monitor --data-binary "@${rendered}")"; action="Created"
fi
if [[ "$code" != "200" ]]; then
  echo "Datadog monitor $(echo "$action" | tr '[:upper:]' '[:lower:]') failed: HTTP ${code}" >&2; cat "$response" >&2; exit 1
fi
python3 -c '
import json, sys
m = json.load(open(sys.argv[1])); site = sys.argv[3]
print("%s Datadog monitor %s: %s" % (sys.argv[2], m["id"], m["name"]))
print("https://app.%s/monitors/%s" % (site, m["id"]))' "$response" "$action" "$SITE"
