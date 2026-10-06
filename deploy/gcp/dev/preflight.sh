#!/bin/bash
# Dev only. Read-only checks before a dev deploy, in order. Each line is PASS,
# FAIL (with the fix) or WARN (optional item). The exit code is 1 when a line
# is FAIL. Run it from a clean checkout of origin/master:
#
#   deploy/gcp/dev/preflight.sh
#
# It changes no GCP resource and no VM state. The IAP SSH session copies
# deploy/ (git archive of HEAD) to a temporary directory on the VM, runs
# host-setup.sh --check and seed-env.sh --check there, and removes the
# directory. gcloud compute ssh can add your SSH key to your OS Login profile
# for 1 h, as every IAP SSH login does.
# SSH_KEY_FILE selects the key for gcloud compute ssh.
#
# "preflight.sh --on-vm" is the part that runs on the VM.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT=darkbloom-dev
ZONE=us-east4-a
INSTANCE=d-inference-dev
SQL_INSTANCE=d-inference-dev-db
TRIGGER=dev-build
BUILD_FILE=deploy/gcp/cloudbuild-prod.yaml
REPO=us-east4-docker.pkg.dev/darkbloom-dev/coordinator/coordinator
OVERRIDES=$SCRIPT_DIR/env-overrides
REQUIRED_FILE=$SCRIPT_DIR/../prod/required-env-keys.txt

status=0
pass() { echo "PASS $*"; }
miss() { echo "FAIL $*"; status=1; }
warn() { echo "WARN $*"; }

if [ "${1:-}" = --on-vm ]; then
    env_file=/etc/d-inference/env
    if ! command -v pg_isready >/dev/null; then
        warn "pg_isready is not on the VM; Cloud SQL reachability not checked. Fix: host-setup.sh --apply"
    elif ! sudo test -f "$env_file"; then
        warn "$env_file does not exist; Cloud SQL reachability not checked. Fix: seed-env.sh --seed"
    else
        hostport=$(sudo awk -F= '$1 == "EIGENINFERENCE_DATABASE_URL" { print substr($0, index($0, "=") + 1) }' "$env_file" |
            sed -E 's#^[a-z]+://([^@/]*@)?([^/?]+).*#\2#')
        host=${hostport%%:*}
        port=${hostport##*:}
        [ "$port" != "$hostport" ] || port=5432
        if [ -n "$host" ] && pg_isready -q -t 5 -h "$host" -p "$port"; then
            pass "Cloud SQL accepts connections from the VM (host from EIGENINFERENCE_DATABASE_URL)"
        else
            miss "Cloud SQL does not accept connections from the VM. Fix: check eigeninference-database-url uses the private IP"
        fi
    fi
    sudo bash "$SCRIPT_DIR/../host-setup.sh" --check 2>&1 | sed 's/^/host-setup --check: /'
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    sudo bash "$SCRIPT_DIR/seed-env.sh" --check 2>&1 | sed 's/^/seed-env --check: /'
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    exit "$status"
fi
[ "$#" = 0 ] || { echo "usage: $0" >&2; exit 2; }

SSH=(gcloud compute ssh "$INSTANCE" --project="$PROJECT" --zone="$ZONE" --tunnel-through-iap
    --ssh-key-expire-after=1h --quiet)
[ -z "${SSH_KEY_FILE:-}" ] || SSH+=(--ssh-key-file="$SSH_KEY_FILE" --strict-host-key-checking=no)
DOMAIN=$(awk -F= '$1 == "DOMAIN" { print substr($0, index($0, "=") + 1); exit }' "$OVERRIDES")

# 1. Local tools.
for cmd in gcloud git dig; do
    command -v "$cmd" >/dev/null || { miss "command $cmd is missing on this machine. Fix: install it"; }
done
[ "$status" = 0 ] || exit 1

# 2. gcloud account and project.
account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)
if [ -n "$account" ] && gcloud auth print-access-token >/dev/null 2>&1; then
    pass "gcloud account $account"
else
    miss "no valid gcloud login. Fix: gcloud auth login"
    exit 1
fi
if [ "$(gcloud projects describe "$PROJECT" --format='value(lifecycleState)' 2>/dev/null)" = ACTIVE ]; then
    pass "project $PROJECT is ACTIVE and readable"
else
    miss "cannot read project $PROJECT. Fix: ask for access to $PROJECT"
fi

# 3. VM.
vm_status=$(gcloud compute instances describe "$INSTANCE" --zone="$ZONE" --project="$PROJECT" \
    --format='value(status)' 2>/dev/null)
vm_ip=$(gcloud compute instances describe "$INSTANCE" --zone="$ZONE" --project="$PROJECT" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
if [ "$vm_status" = RUNNING ]; then
    pass "VM $INSTANCE in $ZONE is RUNNING"
else
    miss "VM $INSTANCE in $ZONE is ${vm_status:-absent}. Fix: apply terraform/compute in Layr-Labs/darkbloom-devnet-infra, or start the VM"
fi

# 4. IAP SSH.
ssh_ok=0
if [ "$vm_status" = RUNNING ] && "${SSH[@]}" --command=true </dev/null >/dev/null 2>&1; then
    ssh_ok=1
    pass "IAP SSH to $INSTANCE"
else
    miss "no IAP SSH to $INSTANCE. Fix: check IAP tunnel access, OS Login admin and actAs on the VM account (infra runbook 08, troubleshooting)"
fi

# 5. DNS.
resolved=$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ')
if [ -n "$vm_ip" ] && [[ " $resolved" == *" $vm_ip "* ]]; then
    pass "DNS: $DOMAIN resolves to the VM external IP"
else
    miss "DNS: $DOMAIN resolves to '${resolved% }', the VM external IP is '${vm_ip:-unknown}'. Fix: set the A record (DBLM-558)"
fi

# 6. Secrets: names only.
while read -r secret; do
    keys=$(awk -F= -v s="secret-manager:$secret" 'substr($0, index($0, "=") + 1) == s { printf "%s ", $1 }' "$OVERRIDES")
    keys=${keys% }
    required=0
    for key in $keys; do grep -Fxq "$key" "$REQUIRED_FILE" && required=1; done
    if [ -n "$(gcloud secrets versions list "$secret" --project="$PROJECT" --filter=state:ENABLED \
        --limit=1 --format='value(name)' 2>/dev/null)" ]; then
        pass "secret $secret has an enabled version"
    elif [ "$required" = 1 ]; then
        miss "secret $secret has no enabled version; required for $keys. Fix: add a version (DBLM-558)"
    else
        warn "secret $secret has no enabled version; optional ($keys)"
    fi
done < <(awk -F= 'substr($0, index($0, "=") + 1) ~ /^secret-manager:/ { print substr($0, index($0, "=") + 16) }' "$OVERRIDES" | sort -u)

# 7. Cloud SQL.
sql_state=$(gcloud sql instances describe "$SQL_INSTANCE" --project="$PROJECT" --format='value(state)' 2>/dev/null)
sql_types=$(gcloud sql instances describe "$SQL_INSTANCE" --project="$PROJECT" --format='value(ipAddresses[].type)' 2>/dev/null)
if [ "$sql_state" = RUNNABLE ] && [[ "$sql_types" == *PRIVATE* ]]; then
    pass "Cloud SQL $SQL_INSTANCE is RUNNABLE with a private IP"
else
    miss "Cloud SQL $SQL_INSTANCE is ${sql_state:-absent} (address types: ${sql_types:-none}). Fix: apply terraform/cloudsql"
fi

# 8. Image of the master head.
master=$(git ls-remote origin refs/heads/master 2>/dev/null | cut -f1)
if [ "$(gcloud builds triggers describe "$TRIGGER" --project="$PROJECT" --format='value(filename)' 2>/dev/null)" = "$BUILD_FILE" ]; then
    pass "trigger $TRIGGER builds $BUILD_FILE"
else
    miss "trigger $TRIGGER is absent or does not build $BUILD_FILE. Fix: infra runbook 07"
fi
if [[ "$master" =~ ^[0-9a-f]{40}$ ]] &&
    [ -n "$(gcloud builds list --project="$PROJECT" --limit=1 \
        --filter="substitutions.COMMIT_SHA=$master AND status=SUCCESS" --format='value(id)' 2>/dev/null)" ] &&
    [[ "$(gcloud artifacts docker images describe "$REPO:${master:0:7}" --project="$PROJECT" \
        --format='value(image_summary.digest)' 2>/dev/null)" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    pass "image $REPO:${master:0:7} of master $master exists"
else
    miss "no SUCCESS $TRIGGER build and image for master ${master:-unknown}. Fix: wait for $TRIGGER, or read gcloud builds list --project=$PROJECT"
fi
if [ "$(git rev-parse HEAD)" != "$master" ] || [ -n "$(git status --porcelain)" ]; then
    miss "this checkout is not a clean origin/master. Fix: use a clean detached worktree at origin/master"
fi

# 9. Host checks on the VM.
if [ "$ssh_ok" = 1 ]; then
    git archive --format=tar.gz HEAD deploy/gcp deploy/environments/prod.env |
        "${SSH[@]}" --command='d=$(mktemp -d) && tar -xz -C "$d" && bash "$d/deploy/gcp/dev/preflight.sh" --on-vm; rc=$?; rm -rf "$d"; exit $rc' ||
        status=1
else
    miss "host checks not run: no IAP SSH"
fi
exit "$status"
