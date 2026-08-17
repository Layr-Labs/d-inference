#!/usr/bin/env bash
# Apply the production backup-integrity monitoring controls to darkbloom-mainnet.
#
#   ./apply.sh            # plan only (default) — read-only, prints what would change
#   ./apply.sh --apply    # create/update. HUMAN-OPERATED ONLY.
#
# Per CLAUDE.md, mutation of production is human-only. This script defaults to
# --plan for that reason: an agent may run the plan, a human runs the apply.
#
# Creation order matters. The "backup missing" policy alerts on the ABSENCE of
# data in a log-based metric (evaluationMissingData: ACTIVE). A freshly created
# log-based metric has no timeseries until the first matching log arrives, and
# automated backups only run once per day. Creating the policy before the metric
# has data pages the on-call immediately for a condition that is not real.
# This script therefore refuses to create that policy until the metric has data.

set -euo pipefail

PROJECT="darkbloom-mainnet"
CHANNEL="projects/${PROJECT}/notificationChannels/9823153599696034473"
METRIC="darkbloom_cloudsql_automated_backup"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="plan"
case "${1:-}" in
  --apply) MODE="apply" ;;
  --plan|"") MODE="plan" ;;
  *) echo "usage: $0 [--plan|--apply]" >&2; exit 2 ;;
esac

say() { printf '\n=== %s ===\n' "$*"; }
would() { if [ "$MODE" = plan ]; then echo "WOULD: $*"; else echo "RUN:   $*"; fi; }

# ---- preflight: the notification channel must exist, or alerts page nobody ----
say "preflight"
if ! gcloud alpha monitoring channels describe "$CHANNEL" --project="$PROJECT" \
      --format='value(displayName,type,enabled)' 2>/dev/null; then
  echo "!! notification channel $CHANNEL not found — refusing to create policies that page nobody" >&2
  exit 1
fi

# The policies below hardcode the production instance name. If production has
# moved, the filters silently match nothing and the controls are decorative.
INSTANCE="d-inference-prod-pg17"
if ! gcloud sql instances describe "$INSTANCE" --project="$PROJECT" \
      --format='value(name,state)' 2>/dev/null; then
  echo "!! Cloud SQL instance $INSTANCE not found — update the filters in this directory before applying" >&2
  exit 1
fi

# ---- 1. log-based metric backing the absence check ----
# A log-based metric does NOT backfill: it only counts log entries written after
# the metric itself was created. So a metric created in this run has no data
# until the next daily backup window, no matter how many backup events already
# exist in the log. METRIC_PREEXISTED gates the absence policy on that fact.
say "log-based metric: $METRIC"
METRIC_PREEXISTED=false
if gcloud logging metrics describe "$METRIC" --project="$PROJECT" >/dev/null 2>&1; then
  echo "exists"
  METRIC_PREEXISTED=true
else
  FILTER=$(jq -r .filter "$HERE/logmetric-cloudsql-automated-backup.json")
  DESC=$(jq -r .description "$HERE/logmetric-cloudsql-automated-backup.json")
  would "gcloud logging metrics create $METRIC"
  if [ "$MODE" = apply ]; then
    gcloud logging metrics create "$METRIC" \
      --project="$PROJECT" \
      --description="$DESC" \
      --log-filter="$FILTER"
  fi
fi

# ---- 2. log-match policies (safe to create immediately) ----
for f in alert-cloudsql-backup-failed.json alert-pd-snapshot-failed.json; do
  NAME=$(jq -r .displayName "$HERE/$f")
  say "policy: $NAME"
  EXISTING=$(gcloud alpha monitoring policies list --project="$PROJECT" \
    --filter="displayName=\"$NAME\"" --format='value(name)' 2>/dev/null | head -1)
  if [ -n "$EXISTING" ]; then
    would "gcloud alpha monitoring policies update $EXISTING --policy-from-file=$f"
    if [ "$MODE" = apply ]; then
      gcloud alpha monitoring policies update "$EXISTING" \
        --project="$PROJECT" --policy-from-file="$HERE/$f"
    fi
  else
    would "gcloud alpha monitoring policies create --policy-from-file=$f"
    if [ "$MODE" = apply ]; then
      gcloud alpha monitoring policies create \
        --project="$PROJECT" --policy-from-file="$HERE/$f"
    fi
  fi
done

# ---- 3. absence policy — gated on the metric having data ----
NAME=$(jq -r .displayName "$HERE/alert-cloudsql-backup-missing.json")
say "policy: $NAME"
BACKUP_EVENTS=""
if [ "$METRIC_PREEXISTED" = true ]; then
  BACKUP_EVENTS=$(gcloud logging read \
    "$(jq -r .filter "$HERE/logmetric-cloudsql-automated-backup.json")" \
    --project="$PROJECT" --freshness=2d --limit=1 --format='value(timestamp)' 2>/dev/null | head -1)
fi

if [ "$METRIC_PREEXISTED" != true ]; then
  cat >&2 <<'GATE'
SKIPPED: the log-based metric was created in this run (or does not exist yet).
Log-based metrics do not backfill — this metric counts only backup events
written from now on, so it has no data until the next daily backup window
regardless of how many backup events already exist in the log. Creating the
absence policy now would page the on-call for a condition that is not real.

Wait for the next window (00:00-04:00 UTC, ~24h), confirm the metric has data
in Metrics Explorer under:
  logging.googleapis.com/user/darkbloom_cloudsql_automated_backup
then re-run this script to create the absence policy.
GATE
elif [ -z "$BACKUP_EVENTS" ]; then
  cat >&2 <<'GATE'
SKIPPED: the metric exists but no automated-backup event was logged in the last
48h, so either backups are already failing (check the 'backup failed' policy and
`gcloud sql backups list`) or the metric filter no longer matches. Creating an
absence policy on top of an already-broken signal would page immediately without
adding information. Resolve the underlying gap first, then re-run.
GATE
else
  echo "metric pre-existed and has backing data (most recent backup event: $BACKUP_EVENTS)"
  EXISTING=$(gcloud alpha monitoring policies list --project="$PROJECT" \
    --filter="displayName=\"$NAME\"" --format='value(name)' 2>/dev/null | head -1)
  if [ -n "$EXISTING" ]; then
    would "gcloud alpha monitoring policies update $EXISTING"
    if [ "$MODE" = apply ]; then
      gcloud alpha monitoring policies update "$EXISTING" \
        --project="$PROJECT" --policy-from-file="$HERE/alert-cloudsql-backup-missing.json"
    fi
  else
    would "gcloud alpha monitoring policies create (backup missing)"
    if [ "$MODE" = apply ]; then
      gcloud alpha monitoring policies create \
        --project="$PROJECT" --policy-from-file="$HERE/alert-cloudsql-backup-missing.json"
    fi
  fi
fi

say "done (mode=$MODE)"
if [ "$MODE" = plan ]; then
  echo "No changes were made. Re-run with --apply as a human operator."
fi
