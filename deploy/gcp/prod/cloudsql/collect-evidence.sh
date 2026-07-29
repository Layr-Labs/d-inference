#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=
INSTANCE_NAME=
OUTPUT_ROOT=

fail() {
  echo "cloudsql evidence: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || fail "--project requires a value"
      PROJECT_ID=$2
      shift 2
      ;;
    --instance)
      [ "$#" -ge 2 ] || fail "--instance requires a value"
      INSTANCE_NAME=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || fail "--output requires a value"
      OUTPUT_ROOT=$2
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -n "$PROJECT_ID" ] || fail "--project is required"
[ -n "$INSTANCE_NAME" ] || fail "--instance is required"
[ -n "$OUTPUT_ROOT" ] || fail "--output is required"
[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "invalid project"
[[ "$INSTANCE_NAME" =~ ^[a-z][a-z0-9-]{0,96}[a-z0-9]$ ]] || fail "invalid instance"
[[ "$OUTPUT_ROOT" = /* ]] || fail "--output must be an absolute path"

command -v gcloud >/dev/null 2>&1 || fail "gcloud is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

STAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
OUTPUT_DIR="$OUTPUT_ROOT/$PROJECT_ID/cloudsql-postgres/$INSTANCE_NAME/$STAMP"
mkdir -p "$OUTPUT_DIR"
chmod 0700 "$OUTPUT_DIR"

echo "cloudsql evidence: collecting into $OUTPUT_DIR"

gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" --format=json > "$OUTPUT_DIR/instance.json"

gcloud sql users list --instance="$INSTANCE_NAME" \
  --project="$PROJECT_ID" --format=json |
  jq 'map(del(.password, .passwordPolicy.status.passwordExpirationTime))' \
  > "$OUTPUT_DIR/users-redacted.json"

gcloud projects get-iam-policy "$PROJECT_ID" --format=json \
  > "$OUTPUT_DIR/project-iam-policy.json"

gcloud compute networks list --project="$PROJECT_ID" --format=json \
  > "$OUTPUT_DIR/networks.json"

gcloud compute addresses list --project="$PROJECT_ID" --global \
  --filter='purpose=VPC_PEERING' --format=json \
  > "$OUTPUT_DIR/private-service-ranges.json"

gcloud services vpc-peerings list --project="$PROJECT_ID" \
  --network="$(jq -r '.settings.ipConfiguration.privateNetwork // "" | split("/")[-1]' "$OUTPUT_DIR/instance.json")" \
  --format=json > "$OUTPUT_DIR/private-service-peerings.json"

gcloud logging sinks list --project="$PROJECT_ID" --format=json \
  > "$OUTPUT_DIR/logging-sinks.json"

gcloud logging buckets list --project="$PROJECT_ID" \
  --location=global --format=json > "$OUTPUT_DIR/logging-buckets-global.json"

gcloud alpha monitoring policies list --project="$PROJECT_ID" --format=json \
  > "$OUTPUT_DIR/monitoring-policies.json" 2> "$OUTPUT_DIR/monitoring-policies.stderr" || true

gcloud sql backups list --instance="$INSTANCE_NAME" \
  --project="$PROJECT_ID" --limit=30 --format=json \
  > "$OUTPUT_DIR/backups.json"

cat > "$OUTPUT_DIR/manifest.json" <<EOF
{
  "project": "$PROJECT_ID",
  "instance": "$INSTANCE_NAME",
  "collected_at_utc": "$STAMP",
  "collector": "$(gcloud config get-value account 2>/dev/null)",
  "method": "deploy/gcp/prod/cloudsql/collect-evidence.sh",
  "contains_secret_values": false
}
EOF

cat > "$OUTPUT_DIR/review.md" <<EOF
# Cloud SQL Evidence Review

| Field | Value |
|---|---|
| Project | \`$PROJECT_ID\` |
| Instance | \`$INSTANCE_NAME\` |
| Collection time | \`$STAMP\` |
| Reviewer | [INSERT] |
| Review date | [INSERT] |
| Change/approval reference | [INSERT] |
| Result | [Pass / Exception] |

## Checks

- [ ] Private IP is configured and no public IP is assigned.
- [ ] SSL mode is \`ENCRYPTED_ONLY\` or stronger.
- [ ] Connector enforcement decision matches the approved migration state.
- [ ] Regional HA decision matches the approved RTO/SLO.
- [ ] Automated backups and PITR are enabled with approved retention.
- [ ] Recent backups succeeded.
- [ ] Deletion protection is enabled.
- [ ] Password policy is enabled for built-in users.
- [ ] Database flags, including pgAudit if selected, match the approved baseline.
- [ ] Project IAM and Cloud SQL access are least privilege.
- [ ] Logging sinks/buckets and retention match policy.
- [ ] Required alerts exist and notification delivery has been tested.
- [ ] Exceptions are linked below.

## Exceptions and Remediation

[INSERT]
EOF

find "$OUTPUT_DIR" -type f -exec chmod 0600 {} +
echo "cloudsql evidence: complete: $OUTPUT_DIR"

