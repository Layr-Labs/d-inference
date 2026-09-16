#!/usr/bin/env bash
#
# Enable percentile aggregators on the coordinator's distribution metrics.
#
# The coordinator submits histograms as DogStatsD distributions (`d`), which the
# local agent forwards as raw values (coordinator/datadog/metrics.go, Histogram).
# Datadog stores those raw values, but a distribution metric only
# answers avg/sum/min/max/count until percentiles are explicitly enabled on it:
# a `p95:` query against a distribution without that flag returns no data. This
# script flips the flag for every metric the dashboard queries with `pNN:`, plus
# any extra metric names passed on the command line.
#
# It does NOT enable percentiles for every histogram the coordinator emits —
# only the ones something actually queries that way, because enabling them
# roughly doubles what that metric bills (a distribution already bills as ~5
# custom metrics per timeseries, ~10 with percentiles).
# To make one more metric answer `pNN:`, pass its full name:
#
#   ./enable-distribution-percentiles.sh --apply d_inference.inference.ttft_ms
#
# It is a one-time, per-metric, per-organization step — not part of a deploy,
# and it must run AFTER the coordinator has flushed each metric at least once
# (Datadog derives metric_type from submitted data and cannot configure a metric
# it has never received). Re-running it is safe: a metric already configured the
# way this script wants is left alone.
#
# The write sets `exclude_tags_mode: true` with an empty `tags` list, which
# means "exclude nothing, keep every submitted tag queryable". The alternative —
# a `tags` allowlist — is a trap: it silently stops resolving every tag key not
# on the list, and the dashboard is not the only consumer (http.latency_ms alone
# is emitted with method, path and status_code).
#
# Usage:
#   ./enable-distribution-percentiles.sh            # --check: report only
#   ./enable-distribution-percentiles.sh --apply    # write the tag configs
#
# Runbook: docs/operations/datadog-dashboard.md
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAYLOAD="${ROOT}/deploy/datadog/dev-network-dashboard.json"
GCP_PROJECT="${DD_GCP_PROJECT:-${GCP_PROJECT:-sepolia-ai}}"

# Only metrics this coordinator submits. A pNN: query against an APM metric or a
# vendor integration must never be handed a metric_type of distribution in a
# shared organization.
NAMESPACE="d_inference."

MODE="check"
EXTRA=""
for arg in "$@"; do
  case "$arg" in
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    "${NAMESPACE}"*) EXTRA="${EXTRA}${arg}
" ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "expected --check, --apply, or a ${NAMESPACE}* metric name" >&2
      exit 2
      ;;
  esac
done

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
  echo "DD_APPLICATION_KEY, DD_APP_KEY, or DD_WRITE_KEY is required for metric tag writes" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The metric names the dashboard queries with a percentile aggregator. Derived
# from the dashboard rather than listed here so a new pNN: widget cannot be
# added without this script covering it.
# ---------------------------------------------------------------------------
metrics="$(python3 - "$PAYLOAD" "$NAMESPACE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    dashboard = json.load(f)

namespace = sys.argv[2]

# p95:d_inference.http.latency_ms{$env,model:$model} by {path}
# The scope braces are optional: `p95:metric` with no filter is a valid query and
# must not be silently uncovered. Both widget query spellings are searched --
# `query` (formulas) and `q` (the older metric_query shape) -- because a metric
# this script misses is a widget that reads No data with nothing to explain why.
QUERY = re.compile(r"p\d+:([a-z0-9_.]+)")
QUERY_KEYS = ("query", "q")

found = set()


def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in QUERY_KEYS and isinstance(value, str):
                found.update(m for m in QUERY.findall(value) if m.startswith(namespace))
            else:
                walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


walk(dashboard)

for metric in sorted(found):
    print(metric)
PY
)"

metrics="$(printf '%s\n%s' "$metrics" "$EXTRA" | sort -u | sed '/^$/d')"

if [[ -z "$metrics" ]]; then
  echo "no pNN:${NAMESPACE}* queries found in ${PAYLOAD} — nothing to enable" >&2
  exit 1
fi

response="$(mktemp)"
trap 'rm -f "$response"' EXIT

# dd_call prints the HTTP status and leaves the body in $response. A transport
# failure prints 000 rather than aborting the run, so the caller reports which
# metric failed instead of the script dying with no output and a half-applied
# set of writes.
dd_call() {
  local method="$1" url="$2" body="${3:-}"
  local args=(-sS -o "$response" -w '%{http_code}'
    -X "$method" "$url"
    -H "Content-Type: application/json"
    -H "DD-API-KEY: ${API_KEY}"
    -H "DD-APPLICATION-KEY: ${APP_KEY}")
  if [[ -n "$body" ]]; then
    args+=(--data-binary "$body")
  fi
  local status
  if ! status="$(curl "${args[@]}" 2>/dev/null)"; then
    : >"$response"
    echo "000"
    return 0
  fi
  echo "${status:-000}"
}

# report_body prints the API's own reason, newline-terminated so it cannot run
# into the next line of output.
report_body() {
  if [[ -s "$response" ]]; then
    sed 's/^/      /' "$response" >&2
    echo >&2
  fi
}

# parse_config prints "<percentiles> <exclude_mode> <metric_type> <tags>" from a
# tag configuration response (tags last, since it is the only field that can be
# long). It never fails the run: an unreadable or unexpected body is a state to
# report, not a reason to abandon the remaining metrics.
# (Keep apostrophes out of this heredoc — bash 3.2 mis-parses one inside a
# command substitution.)
parse_config() {
  python3 - "$response" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        attrs = (json.load(f).get("data") or {}).get("attributes") or {}
except Exception:
    print("unreadable unreadable unreadable -")
    sys.exit(0)


def flag(value):
    return "true" if value is True else "false" if value is False else "unset"


tags = ",".join(sorted(attrs.get("tags") or [])) or "-"
metric_type = attrs.get("metric_type") or "unset"
print("{} {} {} {}".format(
    flag(attrs.get("include_percentiles")),
    flag(attrs.get("exclude_tags_mode")),
    metric_type,
    tags,
))
PY
}

# tag_config_body builds the request. metric_type is required to create a tag
# configuration and is NOT part of the update schema, so sending it on a PATCH
# would make every re-run fail on an unknown attribute.
tag_config_body() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

metric, method = sys.argv[1], sys.argv[2]

attributes = {
    "include_percentiles": True,
    # Empty list with exclude mode on: exclude nothing, keep every submitted
    # tag queryable.
    "exclude_tags_mode": True,
    "tags": [],
}
if method == "POST":
    attributes["metric_type"] = "distribution"

print(json.dumps({
    "data": {
        "id": metric,
        "type": "manage_tags",
        "attributes": attributes,
    }
}))
PY
}

echo "site=${SITE} mode=${MODE}"

total=0
configured=0
unchanged=0
skipped=0
failed=0

while read -r metric; do
  [[ -n "$metric" ]] || continue
  total=$((total + 1))
  url="https://api.${SITE}/api/v2/metrics/${metric}/tags"

  status="$(dd_call GET "$url")"
  case "$status" in
    200)
      read -r have_pct have_exclude have_type have_tags <<<"$(parse_config)"
      echo "  ${metric}: existing config (percentiles=${have_pct} exclude_tags_mode=${have_exclude} type=${have_type} tags=${have_tags})"
      method="PATCH"
      # include_percentiles only exists on a distribution. A pNN: widget pointed
      # at a gauge or count is a dashboard mistake, and Datadog answers it with a
      # 400 that reads like an API problem — so name it here instead.
      if [[ "$have_type" != "distribution" && "$have_type" != "unset" && "$have_type" != "unreadable" ]]; then
        echo "    skipped: ${metric} is a ${have_type}, not a distribution — percentiles do not apply" >&2
        skipped=$((skipped + 1))
        continue
      fi
      if [[ "$have_pct" == "true" && "$have_exclude" == "true" && "$have_tags" == "-" ]]; then
        echo "    already enabled with all tags queryable — no write"
        unchanged=$((unchanged + 1))
        continue
      fi
      # Only an allowlist (exclude mode off) narrows what resolves. A non-empty
      # list with exclude mode already on is a deny-list, so say what it is.
      if [[ "$have_tags" != "-" && "$have_exclude" != "true" ]]; then
        echo "    note: replacing a tag allowlist (${have_tags}) with exclude-nothing"
      elif [[ "$have_tags" != "-" ]]; then
        echo "    note: dropping an existing tag exclusion (${have_tags}) — all tags become queryable"
      fi
      ;;
    404)
      # Either no tag configuration yet, or the metric has never been
      # submitted — a GET cannot tell those apart, so try to create it and let
      # the write say which it was.
      echo "  ${metric}: no config yet"
      method="POST"
      ;;
    000)
      echo "  ${metric}: could not reach https://api.${SITE} (curl failed)" >&2
      failed=$((failed + 1))
      continue
      ;;
    *)
      echo "  ${metric}: GET tags failed (HTTP ${status})" >&2
      report_body
      failed=$((failed + 1))
      continue
      ;;
  esac

  if [[ "$MODE" == "check" ]]; then
    echo "    would ${method} include_percentiles=true exclude_tags_mode=true tags=[]"
    continue
  fi

  status="$(dd_call "$method" "$url" "$(tag_config_body "$metric" "$method")")"
  case "$status" in
    200 | 201)
      echo "    ${method} ok: include_percentiles=true, all tags queryable"
      configured=$((configured + 1))
      ;;
    404)
      # Datadog derives metric_type from submitted data, so a metric it has
      # never received cannot be configured. Usually this means the coordinator
      # has not flushed it yet — or that nothing emits it at all.
      echo "    skipped: Datadog has no data for ${metric} yet"
      skipped=$((skipped + 1))
      ;;
    409)
      # Something created the configuration between our GET and this POST
      # (a concurrent run, or the UI). The desired state may already exist, so
      # this is not a failure — but do not claim we wrote it either.
      echo "    conflict: a tag configuration already exists for ${metric}; re-run to reconcile" >&2
      report_body
      unchanged=$((unchanged + 1))
      ;;
    000)
      echo "    ${method} failed: could not reach https://api.${SITE}" >&2
      failed=$((failed + 1))
      ;;
    *)
      echo "    ${method} failed (HTTP ${status})" >&2
      report_body
      failed=$((failed + 1))
      ;;
  esac
done <<<"$metrics"

if [[ "$MODE" == "check" ]]; then
  echo "checked ${total} metric(s); no writes. Re-run with --apply."
  echo "note: --apply skips any metric Datadog has not received yet, so deploy first."
  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  exit 0
fi

echo "configured=${configured} unchanged=${unchanged} skipped=${skipped} failed=${failed} of ${total}"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

# Every metric skipped means the run achieved nothing — almost always because it
# ran before the coordinator flushed. Exiting 0 there would report success for a
# no-op and the widgets would stay empty with nothing to explain why.
if [[ $((configured + unchanged)) -eq 0 ]]; then
  echo "nothing was configured: Datadog has no data for any of these metrics yet" >&2
  exit 1
fi

echo "done. Percentile aggregators apply to data submitted from now on."
