#!/bin/bash
# Dev only. Deploys the master head to the dev coordinator VM d-inference-dev,
# or rolls back to the image and env file of the last verified swap.
# deploy-dev.yml runs it; a human runs it for the first deploy. Run it from a
# clean checkout of origin/master.
#
#   deploy/gcp/dev/deploy.sh [deploy|rollback] [--dry-run]
#       [--override-pause "<reason>"]
#       [--allow-ci-failure "<exact check/context>"]... [--ci-waiver-reason "<reason>"]
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
# BUILD_WAIT_S and CI_WAIT_S (default 1200 each; both count from the start of
# step 1, so the two waits overlap), GITHUB_OUTPUT (gets deployed=true|false).
set -euo pipefail

MODE=deploy
DRY_RUN=0
OVERRIDE_REASON=""
CI_WAIVER_REASON=""
CI_FAILURE_ALLOWLIST=()
usage() {
    echo "usage: $0 [deploy|rollback] [--dry-run] [--override-pause \"<reason>\"]" \
        "[--allow-ci-failure \"<exact check/context>\"]... [--ci-waiver-reason \"<reason>\"]" >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        deploy|rollback) MODE=$1 ;;
        --dry-run) DRY_RUN=1 ;;
        --override-pause)
            [ -n "${2:-}" ] || usage
            OVERRIDE_REASON=$2
            shift ;;
        --allow-ci-failure)
            [ -n "${2:-}" ] || usage
            CI_FAILURE_ALLOWLIST+=("$2")
            shift ;;
        --ci-waiver-reason)
            [ -n "${2:-}" ] || usage
            CI_WAIVER_REASON=$2
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
REMOTE_STATE=/var/lib/darkbloom-deploy
GITHUB_REPO=Layr-Labs/d-inference
REQUIRED_CHECKS=(
    "Release Integrity" "Docs Lint" "Coordinator Tests" "Coordinator Lint"
    "Prompt Sidecar Tests" "Provider Unit Tests" "Provider SDK Tests"
    "Provider Prompt Parity" "Provider Tests" "Console UI Lint & Build"
    "Swift Build + Cache"
)
# Vercel status contexts report preview deploys of the web projects. They do
# not decide whether the coordinator can deploy, so the gate ignores them.
# jq programs that read status contexts start with this definition.
GATED_STATUS_JQ='def gated: .context | ascii_downcase | startswith("vercel") | not; '
# The jobs of devnet-suite.yml (each name starts with "DevNet suite") test the
# deployed coordinator; they are not a deploy gate either. jq programs that
# read check runs start with this definition.
GATED_RUN_JQ='def gated: .name | startswith("DevNet suite") | not; '
BUILD_WAIT_S=${BUILD_WAIT_S:-1200}
CI_WAIT_S=${CI_WAIT_S:-1200}
MIGRATE_ONLY=${MIGRATE_ONLY:-1}
SHIP=(deploy/gcp/prod deploy/gcp/dev deploy/environments/prod.env)
SSH=(gcloud compute ssh "$INSTANCE" --project="$PROJECT" --zone="$ZONE" --tunnel-through-iap
    --ssh-key-expire-after=1h --quiet)
[ -z "${SSH_KEY_FILE:-}" ] || SSH+=(--ssh-key-file="$SSH_KEY_FILE" --strict-host-key-checking=no)

DEPLOYED=false
output() { echo "deployed=$DEPLOYED"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "deployed=$DEPLOYED" >> "$GITHUB_OUTPUT"; }
trap output EXIT
die() { echo "FAIL $1" >&2; exit "${2:-1}"; }

[[ "$MIGRATE_ONLY" =~ ^[01]$ ]] || die "MIGRATE_ONLY must be 0 or 1" 2
single_line_reason() {
    [ -n "$1" ] && [[ "$1" != *$'\n'* ]] && [[ "$1" != *$'\r'* ]] && [[ "$1" =~ [^[:space:]] ]]
}
[ -z "$OVERRIDE_REASON" ] || single_line_reason "$OVERRIDE_REASON" ||
    die "--override-pause reason must be a nonblank single line" 2
[ -z "$CI_WAIVER_REASON" ] || single_line_reason "$CI_WAIVER_REASON" ||
    die "--ci-waiver-reason must be a nonblank single line" 2
if [ "${#CI_FAILURE_ALLOWLIST[@]}" -gt 0 ] && [ -z "$CI_WAIVER_REASON" ]; then
    die "--allow-ci-failure requires --ci-waiver-reason" 2
fi
if [ -n "$CI_WAIVER_REASON" ] && [ "${#CI_FAILURE_ALLOWLIST[@]}" -eq 0 ]; then
    die "--ci-waiver-reason requires at least one --allow-ci-failure" 2
fi
if [ "${GITHUB_ACTIONS:-false}" = true ] && [ "${#CI_FAILURE_ALLOWLIST[@]}" -gt 0 ]; then
    die "CI failure waivers are human-only and cannot run under GitHub Actions" 2
fi
if [ "${GITHUB_ACTIONS:-false}" = true ] && [ -n "$OVERRIDE_REASON" ]; then
    die "--override-pause is human-only and cannot run under GitHub Actions" 2
fi

operator_identity() {
    local account
    account=${GITHUB_ACTOR:-$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)}
    echo "${account:-unknown} ($(id -un)@$(hostname))"
}

pause_override_reported=0
enforce_pause() { # <initial|live>; live always rereads GitHub immediately before mutation
    local phase=$1 paused pause_source
    if [ "$phase" = initial ] && [ -n "${DEV_DEPLOY_PAUSED+set}" ]; then
        paused=$DEV_DEPLOY_PAUSED
        pause_source=environment
    elif paused=$(gh variable get DEV_DEPLOY_PAUSED -R "$GITHUB_REPO" 2>/dev/null); then
        pause_source="gh variable get"
    else
        paused="<unreadable>"
        pause_source="gh variable get"
    fi
    echo "REPORT DEV_DEPLOY_PAUSED=${paused:-<empty>} (from $pause_source; $phase gate)"
    if [ "$paused" = false ]; then
        return 0
    fi
    if [ -n "$OVERRIDE_REASON" ]; then
        if [ "$pause_override_reported" = 0 ]; then
            echo "REPORT pause override by $(operator_identity): $OVERRIDE_REASON"
            pause_override_reported=1
        fi
    elif [ "$DRY_RUN" = 1 ]; then
        echo "REPORT a real run stops here: deploys are paused or the pause state is unknown"
    else
        die "deploys are paused or the pause state is unknown (DEV_DEPLOY_PAUSED=${paused:-<empty>}); nothing changed. A human can pass --override-pause \"<reason>\"" 3
    fi
}

# The first pause gate comes before every other action and fails closed.
enforce_pause initial

# remote_run <unit> <script> <NAME=value>...: start the script under
# systemd-run, so a dropped SSH session does not stop it, then wait for its
# result file and print its journal. Values must not contain spaces.
remote_run() {
    local unit=$1 script=$2 kv setenv="" out=""
    shift 2
    for kv in "$@"; do setenv="$setenv --setenv=$kv"; done
    local start="sudo systemd-run --quiet --unit=$unit$setenv --setenv=RESULT=$REMOTE/$unit.result /bin/bash $script"
    local wait="for i in \$(seq 1 300); do sudo test -s $REMOTE/$unit.result && break; \
sudo systemctl is-active --quiet $unit || { sleep 2; break; }; sleep 5; done; \
sudo journalctl -u $unit --no-pager -o cat; \
sudo cat $REMOTE/$unit.result 2>/dev/null || echo 'FAIL no result from unit $unit (it stopped early, or it still runs after 25 min)'"
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
    enforce_pause live
    [ "$DRY_RUN" = 1 ] || "${SSH[@]}" --command="sudo test -f $REMOTE/current/deploy/gcp/dev/swap.sh" ||
        die "no verified swap on the VM ($REMOTE/current); nothing to roll back to"
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
step1_start=$(date +%s)
deadline=$(( step1_start + BUILD_WAIT_S ))
ci_deadline=$(( step1_start + CI_WAIT_S ))
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

# read_ci: set checks and statuses to the complete check-run and status-context
# inventories of the candidate; a malformed or truncated answer stops the run.
read_ci() {
    local check_count total_count status_count status_total_count duplicate_statuses
    checks=$(gh api --paginate --slurp "repos/$GITHUB_REPO/commits/$CANDIDATE_COMMIT/check-runs?filter=latest&per_page=100") ||
        die "cannot read GitHub check runs for $CANDIDATE_COMMIT; nothing changed" 3
    statuses=$(gh api --paginate --slurp \
        "repos/$GITHUB_REPO/commits/$CANDIDATE_COMMIT/status?per_page=100") ||
        die "cannot read GitHub status contexts for $CANDIDATE_COMMIT; nothing changed" 3
    check_count=$(printf '%s' "$checks" | jq -r '[.[].check_runs[]] | length') ||
        die "invalid GitHub check-run response for $CANDIDATE_COMMIT; nothing changed" 3
    total_count=$(printf '%s' "$checks" | jq -r 'first(.[].total_count)') ||
        die "invalid GitHub check-run count for $CANDIDATE_COMMIT; nothing changed" 3
    printf '%s' "$statuses" | jq -e '
        type == "array" and length > 0 and
        all(.[];
            (.statuses | type == "array") and
            (.total_count | type == "number") and
            .total_count >= 0 and .total_count == (.total_count | floor)) and
        ([.[].total_count] | unique | length == 1) and
        all(.[].statuses[];
            (.context | type == "string") and (.context | length > 0) and
            (.state | type == "string") and (.state | IN("error", "failure", "pending", "success")))
    ' >/dev/null ||
        die "invalid GitHub status-context response for $CANDIDATE_COMMIT; nothing changed" 3
    [[ "$check_count" =~ ^[0-9]+$ ]] && [[ "$total_count" =~ ^[0-9]+$ ]] &&
        [ "$check_count" -gt 0 ] && [ "$check_count" -eq "$total_count" ] ||
        die "GitHub check-run response is empty or truncated ($check_count/$total_count); nothing changed" 3
    status_count=$(printf '%s' "$statuses" | jq -r '[.[].statuses[]] | length') ||
        die "invalid GitHub status-context count for $CANDIDATE_COMMIT; nothing changed" 3
    status_total_count=$(printf '%s' "$statuses" | jq -r 'first(.[].total_count)') ||
        die "invalid GitHub status-context total for $CANDIDATE_COMMIT; nothing changed" 3
    [[ "$status_count" =~ ^[0-9]+$ ]] && [[ "$status_total_count" =~ ^[0-9]+$ ]] &&
        [ "$status_count" -eq "$status_total_count" ] ||
        die "GitHub status-context response is truncated ($status_count/$status_total_count); nothing changed" 3
    duplicate_statuses=$(printf '%s' "$statuses" | jq -r \
        '[.[].statuses[].context | ascii_downcase] | sort | group_by(.)[] | select(length > 1) | .[0]') ||
        die "invalid GitHub status-context names for $CANDIDATE_COMMIT; nothing changed" 3
    [ -z "$duplicate_statuses" ] ||
        die "GitHub status-context response contains duplicate contexts: $(printf '%s' "$duplicate_statuses" | paste -sd, -); nothing changed" 3
}

# unfinished_required_ci: the required check runs that have not reported or
# not completed, and every pending status context of the gate.
unfinished_required_ci() {
    {
        printf '%s' "$checks" | jq -r --args '[.[].check_runs[]] as $runs | $ARGS.positional[] as $name |
            [$runs[] | select(.name == $name)] as $matching |
            if ($matching | length) == 0 then "\($name) (not reported)"
            elif any($matching[]; .status != "completed") then $name
            else empty end' "${REQUIRED_CHECKS[@]}"
        printf '%s' "$statuses" | jq -r "$GATED_STATUS_JQ"'.[].statuses[] | select(.state == "pending" and gated) | .context'
    } | LC_ALL=C sort -u
}

# verify_ci waits for the required check runs and for every status context
# except Vercel, but not for other check runs: the job that runs this script
# is an unfinished check run of the same commit, and optional workflows such
# as E2E Integration Tests can run longer than the deploy job. Conclusions
# success, neutral and skipped pass, as in GitHub branch protection: ci.yml
# skips path-gated jobs, and a skip caused by a failed dependency shows as the
# failure of that dependency.
verify_ci() {
    local checks statuses pending running ungated failures name allowed found
    while :; do
        read_ci
        pending=$(unfinished_required_ci) ||
            die "invalid GitHub CI response for $CANDIDATE_COMMIT; nothing changed" 3
        [ -n "$pending" ] || break
        pending=$(printf '%s\n' "$pending" | paste -sd, -)
        [ "$DRY_RUN" = 0 ] || die "CI is not complete for $CANDIDATE_COMMIT: $pending"
        [ "$(date +%s)" -lt "$ci_deadline" ] ||
            die "CI is not complete for $CANDIDATE_COMMIT after $CI_WAIT_S s: $pending"
        echo "waiting for CI: $pending"
        sleep 15
    done
    running=$(printf '%s' "$checks" | jq -r '.[].check_runs[] | select(.status != "completed") | .name' |
        LC_ALL=C sort -u | paste -sd, -)
    [ -z "$running" ] || echo "REPORT not required and not finished: $running"
    ungated=$(
        {
            printf '%s' "$checks" | jq -r "$GATED_RUN_JQ"'.[].check_runs[] |
                select(.status == "completed" and (gated | not)) | "\(.name)=\(.conclusion)"'
            printf '%s' "$statuses" | jq -r "$GATED_STATUS_JQ"'.[].statuses[] | select(gated | not) | "\(.context)=\(.state)"'
        } | LC_ALL=C sort -u | paste -sd, -
    )
    [ -z "$ungated" ] || echo "REPORT not a deploy gate: $ungated"
    failures=$(
        {
            printf '%s' "$checks" | jq -r "$GATED_RUN_JQ"'.[].check_runs[] |
                select(.status == "completed" and gated and (.conclusion | IN("success", "neutral", "skipped") | not)) | .name'
            printf '%s' "$statuses" | jq -r "$GATED_STATUS_JQ"'.[].statuses[] |
                select(.state != "success" and .state != "pending" and gated) | .context'
        } | LC_ALL=C sort -u
    )
    if [ -z "$failures" ]; then
        [ "${#CI_FAILURE_ALLOWLIST[@]}" -eq 0 ] ||
            die "CI waiver is stale: no checks fail, but --allow-ci-failure was supplied"
        echo "REPORT GitHub CI/check contexts are green for $CANDIDATE_COMMIT"
        return 0
    fi
    for name in ${CI_FAILURE_ALLOWLIST[@]+"${CI_FAILURE_ALLOWLIST[@]}"}; do
        found=0
        while IFS= read -r allowed; do [ "$name" != "$allowed" ] || found=1; done <<< "$failures"
        [ "$found" = 1 ] || die "CI waiver is stale or misspelled: '$name' is not a current failure"
    done
    while IFS= read -r name; do
        allowed=0
        for found in ${CI_FAILURE_ALLOWLIST[@]+"${CI_FAILURE_ALLOWLIST[@]}"}; do [ "$name" != "$found" ] || allowed=1; done
        [ "$allowed" = 1 ] || die "CI failure is not explicitly waived: $name"
    done <<< "$failures"
    echo "REPORT CI waiver for $CANDIDATE_COMMIT by $(operator_identity): $CI_WAIVER_REASON"
    while IFS= read -r name; do echo "REPORT waived CI failure: $name"; done <<< "$failures"
}

# Recheck mutable authority immediately before the first SSH/file mutation.
verify_ci
LIVE_MASTER=$(git ls-remote origin refs/heads/master | cut -f1)
if [ "$LIVE_MASTER" != "$CANDIDATE_COMMIT" ]; then
    echo "candidate $CANDIDATE_COMMIT is no longer origin/master ($LIVE_MASTER)"
    [ "${ON_SUPERSEDED:-fail}" = skip ] && exit 0
    exit 2
fi
enforce_pause live

# Shell variables do not cross SSH: ship the candidate's files and pass the values.
# A commit directory is immutable while current or rollback-state uses it.
# Extract into a hidden sibling, then rename it into place. A same-SHA redeploy
# reuses an exact tree. A different tree that neither uses is moved aside, and
# the new tree takes its place. A hidden directory older than 60 minutes is
# left by an interrupted run and is removed; a live run uses its own for
# seconds.
LIB=$REMOTE/$CANDIDATE_COMMIT
STAGE_GLOB=".incoming-$(printf '[0-9a-f]%.0s' {1..40}).??????"
extract="/bin/bash -c 'set -euo pipefail
sudo install -d -m 0700 $REMOTE
sudo find $REMOTE -mindepth 1 -maxdepth 1 -type d -name \"$STAGE_GLOB\" -mmin +60 -exec rm -rf -- {} +
stage=\$(sudo mktemp -d $REMOTE/.incoming-$CANDIDATE_COMMIT.XXXXXX)
cleanup_stage() { [ -z \"\$stage\" ] || sudo rm -rf -- \"\$stage\"; }
trap cleanup_stage EXIT
sudo tar -xz --no-same-owner -C \"\$stage\"
tree_digest() {
    sudo tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu \\
        -cf - -C \"\$1\" . | sha256sum | cut -d\" \" -f1
}
# A link or state file that cannot be read counts as a use, and so does a
# rollback-state whose line 6 is neither none nor an absolute path.
in_use() {
    local target
    if sudo test -e $REMOTE/current || sudo test -L $REMOTE/current; then
        target=\$(sudo readlink -f $REMOTE/current) || return 0
        if sudo test \"\$target\" -ef $LIB; then return 0; fi
    fi
    if sudo test -e $REMOTE_STATE/rollback-state; then
        target=\$(sudo sed -n 6p $REMOTE_STATE/rollback-state) || return 0
        case \"\$target\" in none) return 1 ;; /*) ;; *) return 0 ;; esac
        if sudo test \"\$target\" -ef $LIB; then return 0; fi
    fi
    return 1
}
if sudo test -e $LIB || sudo test -L $LIB; then
    sudo test -d $LIB && ! sudo test -L $LIB ||
        { echo \"FAIL published candidate path is not a directory\" >&2; exit 1; }
    staged_digest=\$(tree_digest \"\$stage\") ||
        { echo \"FAIL could not hash staged candidate files\" >&2; exit 1; }
    published_digest=\$(tree_digest $LIB) ||
        { echo \"FAIL could not hash published candidate files\" >&2; exit 1; }
    [[ \"\$staged_digest\" =~ ^[0-9a-f]{64}\$ ]] &&
        [[ \"\$published_digest\" =~ ^[0-9a-f]{64}\$ ]] ||
        { echo \"FAIL candidate tree digest is malformed\" >&2; exit 1; }
    if [ \"\$staged_digest\" != \"\$published_digest\" ]; then
        ! in_use || { echo \"FAIL published candidate files differ from the same commit archive, and current or rollback-state uses them\" >&2; exit 1; }
        aside=\$(sudo mktemp -d $REMOTE/.incoming-$CANDIDATE_COMMIT.XXXXXX)
        sudo mv -T -- $LIB \"\$aside\" ||
            { echo \"FAIL could not move the published candidate files aside; nothing changed\" >&2; exit 1; }
        if ! sudo mv -T -- \"\$stage\" $LIB; then
            sudo mv -T -- \"\$aside\" $LIB ||
                { echo \"FAIL could not publish $LIB or restore it: the old files are in \$aside\" >&2; exit 1; }
            echo \"FAIL could not publish the new candidate files; restored the old files in $LIB\" >&2
            exit 1
        fi
        stage=\$aside
        echo \"REPORT replaced unused published candidate files that differ from the same commit archive\"
    fi
    sudo rm -rf -- \"\$stage\"
else
    sudo mv -T -- \"\$stage\" $LIB
fi
stage=
trap - EXIT'"
if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN ship git archive $CANDIDATE_COMMIT: ${SHIP[*]}"
    echo "DRY-RUN ssh: $extract"
else
    git archive --format=tar.gz "$CANDIDATE_COMMIT" "${SHIP[@]}" | "${SSH[@]}" --command="$extract"
fi
remote_run "darkbloom-dev-swap-${CANDIDATE_COMMIT:0:7}-$(date +%s)" "$LIB/deploy/gcp/dev/swap.sh" \
    MODE=deploy LIB="$LIB" CANDIDATE_COMMIT="$CANDIDATE_COMMIT" CANDIDATE_VERSION="$CANDIDATE_VERSION" \
    CANDIDATE_DIGEST="$CANDIDATE_DIGEST" MIGRATE_ONLY="$MIGRATE_ONLY" || die "swap failed; read the lines above"
[ "$DRY_RUN" = 1 ] || DEPLOYED=true
