#!/usr/bin/env bash
set -euo pipefail

MODE=${1:---plan}
CONFIG_FILE=${CONFIG_FILE:-}

fail() {
  echo "cloudsql provision: $*" >&2
  exit 1
}

case "$MODE" in
  --plan|--apply) ;;
  *) fail "usage: CONFIG_FILE=/secure/path/config.env $0 [--plan|--apply]" ;;
esac

[ -n "$CONFIG_FILE" ] || fail "CONFIG_FILE is required"
[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] ||
  fail "CONFIG_FILE must be an existing regular file, not a symlink"

# The configuration file must contain only simple KEY=VALUE assignments.
if ! awk '
  /^[[:space:]]*($|#)/ { next }
  !/^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:\/-]+$/ { bad=1; print "invalid config line " NR > "/dev/stderr" }
  END { exit bad }
' "$CONFIG_FILE"; then
  fail "configuration contains unsupported syntax"
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

required_vars=(
  PROJECT_ID INSTANCE_NAME REGION DATABASE_VERSION EDITION TIER
  STORAGE_SIZE_GB STORAGE_TYPE NETWORK PRIVATE_SERVICE_RANGE
  PRIVATE_SERVICE_PREFIX_LENGTH AVAILABILITY_TYPE BACKUP_START_TIME
  BACKUP_LOCATION RETAINED_BACKUPS_COUNT RETAINED_TRANSACTION_LOG_DAYS
  MAINTENANCE_WINDOW_DAY MAINTENANCE_WINDOW_HOUR PASSWORD_MIN_LENGTH
  PASSWORD_REUSE_INTERVAL ENABLE_PGAUDIT
)

for name in "${required_vars[@]}"; do
  [ -n "${!name:-}" ] || fail "missing required configuration: $name"
done

[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "invalid PROJECT_ID"
[[ "$INSTANCE_NAME" =~ ^[a-z][a-z0-9-]{0,96}[a-z0-9]$ ]] || fail "invalid INSTANCE_NAME"
[[ "$REGION" =~ ^[a-z]+-[a-z0-9]+[0-9]$ ]] || fail "invalid REGION"
[[ "$NETWORK" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || fail "invalid NETWORK"
[[ "$PRIVATE_SERVICE_RANGE" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || fail "invalid PRIVATE_SERVICE_RANGE"
[[ "$DATABASE_VERSION" =~ ^POSTGRES_(1[4-8])$ ]] || fail "DATABASE_VERSION must be POSTGRES_14 through POSTGRES_18"
[[ "$EDITION" =~ ^(enterprise|enterprise-plus)$ ]] || fail "invalid EDITION"
[[ "$STORAGE_TYPE" =~ ^(SSD|HDD)$ ]] || fail "invalid STORAGE_TYPE"
[[ "$AVAILABILITY_TYPE" =~ ^(REGIONAL|ZONAL)$ ]] || fail "invalid AVAILABILITY_TYPE"
[[ "$ENABLE_PGAUDIT" =~ ^(true|false)$ ]] || fail "ENABLE_PGAUDIT must be true or false"

for name in STORAGE_SIZE_GB PRIVATE_SERVICE_PREFIX_LENGTH RETAINED_BACKUPS_COUNT \
  RETAINED_TRANSACTION_LOG_DAYS MAINTENANCE_WINDOW_DAY MAINTENANCE_WINDOW_HOUR \
  PASSWORD_MIN_LENGTH PASSWORD_REUSE_INTERVAL; do
  [[ "${!name}" =~ ^[0-9]+$ ]] || fail "$name must be numeric"
done

command -v gcloud >/dev/null 2>&1 || fail "gcloud is required"

echo "cloudsql provision: validating project and network"
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null
gcloud compute networks describe "$NETWORK" \
  --project="$PROJECT_ID" --format='value(name)' >/dev/null

instance_exists=false
if gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" --format='value(name)' >/dev/null 2>&1; then
  instance_exists=true
fi

range_exists=false
if gcloud compute addresses describe "$PRIVATE_SERVICE_RANGE" \
  --project="$PROJECT_ID" --global --format='value(name)' >/dev/null 2>&1; then
  range_exists=true
fi

flags=()
if [ "$ENABLE_PGAUDIT" = true ]; then
  flags+=(--database-flags=cloudsql.enable_pgaudit=on)
fi

create_command=(
  gcloud sql instances create "$INSTANCE_NAME"
  --project="$PROJECT_ID"
  --database-version="$DATABASE_VERSION"
  --edition="$EDITION"
  --tier="$TIER"
  --region="$REGION"
  --availability-type="$AVAILABILITY_TYPE"
  --network="$NETWORK"
  --no-assign-ip
  --data-api-access=DISALLOW_DATA_API
  --ssl-mode=ENCRYPTED_ONLY
  --storage-type="$STORAGE_TYPE"
  --storage-size="$STORAGE_SIZE_GB"
  --storage-auto-increase
  --backup-start-time="$BACKUP_START_TIME"
  --backup-location="$BACKUP_LOCATION"
  --enable-point-in-time-recovery
  --retained-backups-count="$RETAINED_BACKUPS_COUNT"
  --retained-transaction-log-days="$RETAINED_TRANSACTION_LOG_DAYS"
  --retain-backups-on-delete
  --deletion-protection
  --maintenance-window-day="$MAINTENANCE_WINDOW_DAY"
  --maintenance-window-hour="$MAINTENANCE_WINDOW_HOUR"
  --maintenance-release-channel=production
  --enable-password-policy
  --password-policy-min-length="$PASSWORD_MIN_LENGTH"
  --password-policy-complexity=COMPLEXITY_DEFAULT
  --password-policy-reuse-interval="$PASSWORD_REUSE_INTERVAL"
  --password-policy-disallow-username-substring
  --connector-enforcement=NOT_REQUIRED
  "${flags[@]}"
)

print_command() {
  printf '  %q' "$@"
  printf '\n'
}

if [ "$instance_exists" = true ]; then
  echo "cloudsql provision: instance already exists; refusing to alter it"
  gcloud sql instances describe "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --format='yaml(name,region,databaseVersion,settings.edition,settings.tier,settings.availabilityType,settings.ipConfiguration,settings.backupConfiguration,deletionProtection)'
  exit 2
fi

if [ "$MODE" = "--plan" ]; then
  if [ "$range_exists" = false ]; then
    echo "cloudsql provision: private services range would be created:"
    print_command gcloud compute addresses create "$PRIVATE_SERVICE_RANGE" \
      --project="$PROJECT_ID" --global --purpose=VPC_PEERING \
      --prefix-length="$PRIVATE_SERVICE_PREFIX_LENGTH" --network="$NETWORK"
  else
    echo "cloudsql provision: using existing private services range $PRIVATE_SERVICE_RANGE"
  fi

  echo "cloudsql provision: private services connection must exist or be created:"
  print_command gcloud services vpc-peerings connect \
    --project="$PROJECT_ID" --service=servicenetworking.googleapis.com \
    --ranges="$PRIVATE_SERVICE_RANGE" --network="$NETWORK"

  echo "cloudsql provision: instance would be created:"
  print_command "${create_command[@]}"
  echo "cloudsql provision: plan complete; no changes made"
  exit 0
fi

echo "cloudsql provision: APPLY requested by human operator"
gcloud services enable sqladmin.googleapis.com servicenetworking.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com \
  --project="$PROJECT_ID"

if [ "$range_exists" = false ]; then
  gcloud compute addresses create "$PRIVATE_SERVICE_RANGE" \
    --project="$PROJECT_ID" --global --purpose=VPC_PEERING \
    --prefix-length="$PRIVATE_SERVICE_PREFIX_LENGTH" --network="$NETWORK"
fi

gcloud services vpc-peerings connect \
  --project="$PROJECT_ID" --service=servicenetworking.googleapis.com \
  --ranges="$PRIVATE_SERVICE_RANGE" --network="$NETWORK"

"${create_command[@]}"

echo "cloudsql provision: created $INSTANCE_NAME"
echo "cloudsql provision: next steps are database migration, user/grant review, proxy canary, evidence collection, and restore testing"
