#!/bin/bash
# Dev only. Deploys the master head to the dev coordinator VM d-inference-dev,
# or rolls back to the image and env file of the last verified swap.
# deploy-dev.yml runs it; a human runs it for the first deploy. Run it from a
# clean checkout of origin/master.
#
#   deploy/gcp/dev/deploy.sh [deploy|rollback] [--dry-run] [--override-pause "<reason>"]
#
# Pause: before any change, the script reads the repository variable
# DEV_DEPLOY_PAUSED (the DEV_DEPLOY_PAUSED environment variable when it is set,
# for example from vars.DEV_DEPLOY_PAUSED in GitHub Actions; else
# gh variable get). It continues only when the value is "false". "true", an
# empty value or a failed read stops the script, unless a human passes
# --override-pause with a reason. --dry-run reports the pause and continues.
#
# deploy: docs/operations/coordinator-deploy.md step 1 (the candidate is
# origin/master, trigger dev-build builds deploy/gcp/cloudbuild-prod.yaml, a
# SUCCESS build of the candidate exists, the image digest), then it ships the
# candidate's deploy files over IAP SSH and runs deploy/gcp/dev/swap.sh under
# systemd-run (steps 2 to 4, Verification, Rollback).
# --dry-run: read-only step 1, then print what it would ship and run.
#
# Environment: SSH_KEY_FILE (key for gcloud compute ssh), MIGRATE_ONLY (1 =
# run --migrate-only before the drain, the default; 0 = skip),
# ON_SUPERSEDED=skip (exit 0 when the candidate is no longer origin/master),
# BUILD_WAIT_S (default 1200), GITHUB_OUTPUT (gets deployed=true|false).
set -euo pipefail

MODE=deploy
DRY_RUN=0
OVERRIDE_REASON=""
usage() { echo "usage: $0 [deploy|rollback] [--dry-run] [--override-pause \"<reason>\"]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        deploy|rollback) MODE=$1 ;;
        --dry-run) DRY_RUN=1 ;;
        --override-pause)
            [ -n "${2:-}" ] || usage
            OVERRIDE_REASON=$2
            shift ;;
        *) usage ;;
    esac
    shift
done

PROJECT=darkbloom-dev
ZONE=us-east4-a
INSTANCE=d-inference-dev
TRIGGER=dev-build
BUILD_FILE=deploy/gcp/cloudbuild-prod.yaml
REPO=us-east4-docker.pkg.dev/darkbloom-dev/coordinator/coordinator
REMOTE=/usr/local/lib/darkbloom-deploy
GITHUB_REPO=Layr-Labs/d-inference
BUILD_WAIT_S=${BUILD_WAIT_S:-1200}
MIGRATE_ONLY=${MIGRATE_ONLY:-1}
SHIP=(deploy/gcp/prod deploy/gcp/dev deploy/environments/prod.env)
SSH=(gcloud compute ssh "$INSTANCE" --project="$PROJECT" --zone="$ZONE" --tunnel-through-iap
    --ssh-key-expire-after=1h --quiet)
[ -z "${SSH_KEY_FILE:-}" ] || SSH+=(--ssh-key-file="$SSH_KEY_FILE" --strict-host-key-checking=no)

DEPLOYED=false
output() { echo "deployed=$DEPLOYED"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "deployed=$DEPLOYED" >> "$GITHUB_OUTPUT"; }
trap output EXIT
die() { echo "FAIL $*" >&2; exit "${2:-1}"; }

[[ "$MIGRATE_ONLY" =~ ^[01]$ ]] || die "MIGRATE_ONLY must be 0 or 1" 2

# The pause gate comes before any change and fails closed.
if [ -n "${DEV_DEPLOY_PAUSED+set}" ]; then
    paused=$DEV_DEPLOY_PAUSED
    source="environment"
elif paused=$(gh variable get DEV_DEPLOY_PAUSED -R "$GITHUB_REPO" 2>/dev/null); then
    source="gh variable get"
else
    paused="<unreadable>"
    source="gh variable get"
fi
echo "REPORT DEV_DEPLOY_PAUSED=${paused:-<empty>} (from $source)"
if [ "$paused" != false ]; then
    if [ -n "$OVERRIDE_REASON" ]; then
        actor=${GITHUB_ACTOR:-$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)}
        echo "REPORT pause override by ${actor:-unknown} ($(id -un)@$(hostname)): $OVERRIDE_REASON"
    elif [ "$DRY_RUN" = 1 ]; then
        echo "REPORT a real run stops here: deploys are paused or the pause state is unknown"
    else
        die "deploys are paused or the pause state is unknown (DEV_DEPLOY_PAUSED=${paused:-<empty>}); nothing changed. A human can pass --override-pause \"<reason>\"" 3
    fi
fi

# remote_run <unit> <script> <NAME=value>...: start the script under
# systemd-run, so a dropped SSH session does not stop it, then wait for its
# result file and print its journal. Values must not contain spaces.
remote_run() {
    local unit=$1 script=$2 kv setenv="" out=""
    shift 2
    for kv in "$@"; do setenv="$setenv --setenv=$kv"; done
    local start="sudo systemd-run --quiet --unit=$unit$setenv --setenv=RESULT=$REMOTE/$unit.result /bin/bash $script"
    local wait="for i in \$(seq 1 300); do sudo test -s $REMOTE/$unit.result && break; sleep 5; done; \
sudo journalctl -u $unit --no-pager -o cat; \
sudo cat $REMOTE/$unit.result 2>/dev/null || echo 'FAIL no result after 25 min; the unit $unit may still run'"
    if [ "$DRY_RUN" = 1 ]; then
        echo "DRY-RUN ssh: $start"
        echo "DRY-RUN ssh: wait for $REMOTE/$unit.result, print the journal of $unit"
        return 0
    fi
    "${SSH[@]}" --command="$start"
    for _ in 1 2 3; do
        if out=$("${SSH[@]}" --command="$wait"); then break; fi
        sleep 10
    done
    printf '%s\n' "$out"
    [[ "$(printf '%s\n' "$out" | tail -n 1)" == OK* ]]
}

if [ "$MODE" = rollback ]; then
    remote_run "darkbloom-dev-rollback-$(date +%s)" "$REMOTE/current/deploy/gcp/dev/swap.sh" \
        MODE=rollback LIB="$REMOTE/current" || die "rollback failed; read the lines above"
    [ "$DRY_RUN" = 1 ] || DEPLOYED=true
    exit 0
fi

# Runbook step 1: pin the candidate.
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean" 2
CANDIDATE_COMMIT=$(git rev-parse HEAD)
MASTER=$(git ls-remote origin refs/heads/master | cut -f1)
if [ "$MASTER" != "$CANDIDATE_COMMIT" ]; then
    echo "candidate $CANDIDATE_COMMIT is not origin/master ($MASTER)"
    [ "${ON_SUPERSEDED:-fail}" = skip ] && exit 0
    exit 2
fi
CANDIDATE_VERSION=$(awk -F'"' '/^var LatestProviderVersion =/ { print $2 }' coordinator/api/server.go)
[[ "$CANDIDATE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot read LatestProviderVersion" 2
CANDIDATE_IMAGE="$REPO:${CANDIDATE_COMMIT:0:7}"
[ "$(gcloud builds triggers describe "$TRIGGER" --project="$PROJECT" --format='value(filename)')" = "$BUILD_FILE" ] ||
    die "trigger $TRIGGER does not build $BUILD_FILE" 2
TRIGGER_ID=$(gcloud builds triggers describe "$TRIGGER" --project="$PROJECT" --format='value(id)')
FILTER="buildTriggerId=$TRIGGER_ID AND substitutions.COMMIT_SHA=$CANDIDATE_COMMIT"
deadline=$(( $(date +%s) + BUILD_WAIT_S ))
while :; do
    built=$(gcloud builds list --project="$PROJECT" --limit=1 --sort-by=~createTime \
        --filter="$FILTER AND status=SUCCESS" --format='value(id)')
    [ -z "$built" ] || break
    last=$(gcloud builds list --project="$PROJECT" --limit=1 --sort-by=~createTime \
        --filter="$FILTER" --format='value(id,status)')
    case "${last##*[[:space:]]}" in
        FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED|EXPIRED) die "$TRIGGER build ${last%%[[:space:]]*} is ${last##*[[:space:]]}" ;;
    esac
    [ "$DRY_RUN" = 0 ] || die "no SUCCESS $TRIGGER build of $CANDIDATE_COMMIT yet (last: ${last:-none})"
    [ "$(date +%s)" -lt "$deadline" ] || die "no SUCCESS $TRIGGER build of $CANDIDATE_COMMIT after $BUILD_WAIT_S s"
    echo "waiting for $TRIGGER: ${last:-not created yet}"
    sleep 15
done
CANDIDATE_DIGEST=$(gcloud artifacts docker images describe "$CANDIDATE_IMAGE" \
    --project="$PROJECT" --format='value(image_summary.digest)')
[[ "$CANDIDATE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no digest for $CANDIDATE_IMAGE" 2
echo "build=$built image=$CANDIDATE_IMAGE digest=$CANDIDATE_DIGEST version=$CANDIDATE_VERSION"

# Shell variables do not cross SSH: ship the candidate's files and pass the values.
LIB=$REMOTE/$CANDIDATE_COMMIT
extract="sudo install -d -m 0700 $REMOTE && sudo rm -rf $LIB && sudo install -d -m 0700 $LIB && sudo tar -xz --no-same-owner -C $LIB"
if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN ship git archive HEAD: ${SHIP[*]}"
    echo "DRY-RUN ssh: $extract"
else
    git archive --format=tar.gz HEAD "${SHIP[@]}" | "${SSH[@]}" --command="$extract"
fi
remote_run "darkbloom-dev-swap-${CANDIDATE_COMMIT:0:7}-$(date +%s)" "$LIB/deploy/gcp/dev/swap.sh" \
    MODE=deploy LIB="$LIB" CANDIDATE_COMMIT="$CANDIDATE_COMMIT" CANDIDATE_VERSION="$CANDIDATE_VERSION" \
    CANDIDATE_DIGEST="$CANDIDATE_DIGEST" MIGRATE_ONLY="$MIGRATE_ONLY" || die "swap failed; read the lines above"
[ "$DRY_RUN" = 1 ] || DEPLOYED=true
