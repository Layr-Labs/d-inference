#!/usr/bin/env bash
# deploy.sh — DAR-327 Phase 2: true blue-green coordinator deploy orchestrator.
#
# Runs ON the GCE coordinator box. Performs a zero-downtime color swap:
#
#   1. detect the active color from the on-box Caddyfile upstream port
#   2. (optional) pin the new image for the idle color
#   3. start the IDLE color           (systemctl start darkbloom-coordinator@<idle>)
#   4. wait for idle /health AND /readyz  (DAR-327 Phase 1 endpoints)
#   5. flip the Caddy upstream old->new + graceful `caddy reload`  (cutover)
#   6. drain the OLD color            (POST /v1/admin/drain, Phase 1) until inflight==0
#   7. stop the OLD color             (systemctl stop darkbloom-coordinator@<old>)
#
# Stopping the old color triggers the coordinator's `going_away` provider
# broadcast (DAR-327 Phase 3, separate PR) so providers reconnect to the new
# color instantly instead of waiting for a heartbeat timeout. This script only
# performs the graceful stop; the broadcast itself ships in Phase 3.
#
# ROLLBACK (valid any time AFTER the flip and BEFORE the old color is stopped):
#   ./deploy.sh --rollback
# flips the Caddy upstream back to the still-running previous color and reloads.
#
# SAFETY:
#   * --dry-run prints the full plan and mutates NOTHING.
#   * destructive steps require interactive confirmation (skip with -y/--yes).
#   * the Caddy port flip is the self-contained, unit-tested function
#     flip_upstream(); see deploy/gcp/prod/deploy_test.sh.
#   * sourcing this file (e.g. from the test) defines the functions but NEVER
#     runs main — see the BASH_SOURCE guard at the bottom.
#   * NO secrets are read or written here; coordinator secrets stay in
#     /etc/d-inference/env (Secret Manager -> tmpfs -> --env-file).
#
# Cross-phase contracts (separate PRs; referenced, not implemented here):
#   Phase 1 : GET /readyz  +  POST /v1/admin/drain
#   Phase 3 : graceful coordinator stop broadcasts `going_away`

# NOTE: shell options are set inside main() so that sourcing this file for tests
# does not mutate the caller's shell. The functions below are written to not
# depend on `set -e`.

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment)
# ---------------------------------------------------------------------------
CADDYFILE_DEFAULT="/etc/caddy/Caddyfile"
CADDYFILE="${CADDYFILE:-}"
BLUE_PORT="${BLUE_PORT:-8080}"
GREEN_PORT="${GREEN_PORT:-8081}"
HEALTH_HOST="${HEALTH_HOST:-127.0.0.1}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
READYZ_PATH="${READYZ_PATH:-/readyz}"
DRAIN_PATH="${DRAIN_PATH:-/v1/admin/drain}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"
CADDY_BIN="${CADDY_BIN:-caddy}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
CURL_BIN="${CURL_BIN:-curl}"
DINF_DEPLOY_ENV="${DINF_DEPLOY_ENV:-/etc/d-inference/deploy.env}"

# Runtime flags (main overrides from CLI args).
DRY_RUN="${DRY_RUN:-0}"
ROLLBACK=0
ASSUME_YES=0
IMAGE_REF=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARNING: %s\n' "$*" >&2; }
err()  { printf '[deploy] ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ===========================================================================
# Pure, unit-tested helpers (no side effects beyond the named file).
# ===========================================================================

# flip_upstream <caddyfile> <from_port> <to_port>
#
# Rewrites ONLY the coordinator upstream line inside the (coordinator_routes)
# snippet:
#     reverse_proxy 127.0.0.1:<from_port>  ->  reverse_proxy 127.0.0.1:<to_port>
# The step-ca (https://127.0.0.1:9000) and MicroMDM (https://127.0.0.1:9002)
# upstreams are NOT touched: they use the https:// scheme and different ports.
# All other bytes — indentation, comments, the proxy block body — are preserved,
# and the original file's inode/permissions are kept (in-place truncate+write).
#
# Returns: 0 = at least one upstream line flipped; 2 = bad args/missing file;
#          3 = no matching upstream line found (file left untouched).
flip_upstream() {
  if [ "$#" -ne 3 ]; then
    echo "flip_upstream: usage: flip_upstream <caddyfile> <from_port> <to_port>" >&2
    return 2
  fi
  local caddyfile="$1" from_port="$2" to_port="$3"
  if [ ! -f "$caddyfile" ]; then
    echo "flip_upstream: file not found: $caddyfile" >&2
    return 2
  fi
  local tmp
  tmp="$(mktemp)" || return 2

  awk -v fromp="$from_port" -v top="$to_port" '
    # Only the coordinator upstream: a reverse_proxy to bare loopback (no
    # https:// scheme) on the from-port, delimited so :808 never matches :8080.
    /^[[:space:]]*reverse_proxy[[:space:]]+127\.0\.0\.1:/ && $0 !~ /https:\/\// {
      if ($0 ~ ("127\\.0\\.0\\.1:" fromp "([^0-9]|$)")) {
        sub("127\\.0\\.0\\.1:" fromp, "127.0.0.1:" top)
        changed++
      }
    }
    { print }
    END { exit (changed + 0 == 0) ? 3 : 0 }
  ' "$caddyfile" > "$tmp"
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  if ! cat "$tmp" > "$caddyfile"; then
    rm -f "$tmp"
    echo "flip_upstream: failed to write $caddyfile" >&2
    return 2
  fi
  rm -f "$tmp"
  return 0
}

# current_upstream_port <caddyfile>
# Prints the coordinator upstream port (the blue-green swap target). Returns 3
# if no coordinator upstream line is present.
current_upstream_port() {
  if [ "$#" -ne 1 ]; then
    echo "current_upstream_port: usage: current_upstream_port <caddyfile>" >&2
    return 2
  fi
  local caddyfile="$1"
  if [ ! -f "$caddyfile" ]; then
    echo "current_upstream_port: file not found: $caddyfile" >&2
    return 2
  fi
  awk '
    /^[[:space:]]*reverse_proxy[[:space:]]+127\.0\.0\.1:/ && $0 !~ /https:\/\// {
      if (match($0, /127\.0\.0\.1:[0-9]+/)) {
        tok = substr($0, RSTART, RLENGTH)
        sub(/.*:/, "", tok)
        print tok
        found = 1
        exit
      }
    }
    END { if (found != 1) exit 3 }
  ' "$caddyfile"
}

port_for_color() {
  case "$1" in
    blue)  echo "$BLUE_PORT" ;;
    green) echo "$GREEN_PORT" ;;
    *) echo "port_for_color: unknown color: $1" >&2; return 2 ;;
  esac
}

color_for_port() {
  if [ "$1" = "$BLUE_PORT" ]; then
    echo blue
  elif [ "$1" = "$GREEN_PORT" ]; then
    echo green
  else
    echo "color_for_port: port '$1' is neither blue($BLUE_PORT) nor green($GREEN_PORT)" >&2
    return 2
  fi
}

other_color() {
  case "$1" in
    blue)  echo green ;;
    green) echo blue ;;
    *) echo "other_color: unknown color: $1" >&2; return 2 ;;
  esac
}

# ===========================================================================
# Effectful helpers (dry-run aware).
# ===========================================================================

run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN exec: $*"
    return 0
  fi
  "$@"
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local prompt="$1" ans
  printf '%s [y/N] ' "$prompt" >&2
  if ! IFS= read -r ans; then
    return 1
  fi
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

http_code() {
  # No -f: we WANT the real status code for 4xx/5xx (not a curl error). On a
  # connection failure curl prints "000"; default to 000 if it prints nothing.
  local code
  code="$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

reload_caddy() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would run: $CADDY_BIN validate --config $CADDYFILE --adapter caddyfile"
    log "DRY-RUN: would run: $CADDY_BIN reload --config $CADDYFILE --adapter caddyfile"
    return 0
  fi
  log "Validating Caddyfile ($CADDYFILE)..."
  if ! "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile; then
    err "caddy validate failed; not reloading"
    return 1
  fi
  log "Reloading Caddy (graceful, zero-downtime)..."
  "$CADDY_BIN" reload --config "$CADDYFILE" --adapter caddyfile
}

pin_image() {
  local ref="$1"
  log "Pinning idle-color image: DINF_IMAGE=$ref -> $DINF_DEPLOY_ENV"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would write DINF_IMAGE=$ref to $DINF_DEPLOY_ENV (read by darkbloom-run.sh via EnvironmentFile)"
    return 0
  fi
  local dir tmp
  dir="$(dirname "$DINF_DEPLOY_ENV")"
  mkdir -p "$dir"
  tmp="$(mktemp)" || die "mktemp failed"
  if [ -f "$DINF_DEPLOY_ENV" ]; then
    grep -v '^DINF_IMAGE=' "$DINF_DEPLOY_ENV" > "$tmp" || true
  fi
  printf 'DINF_IMAGE=%s\n' "$ref" >> "$tmp"
  cat "$tmp" > "$DINF_DEPLOY_ENV"
  rm -f "$tmp"
  chmod 644 "$DINF_DEPLOY_ENV"
}

# wait_healthy <color> <port> — poll /health AND /readyz until both 200 or timeout.
wait_healthy() {
  local color="$1" port="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would poll http://${HEALTH_HOST}:${port}${HEALTH_PATH} AND ${READYZ_PATH} until 200 (timeout ${HEALTH_TIMEOUT}s)"
    return 0
  fi
  log "Waiting for $color (port $port) /health + /readyz (timeout ${HEALTH_TIMEOUT}s)..."
  local now deadline h r
  now="$(date +%s)"
  deadline=$(( now + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    h="$(http_code "http://${HEALTH_HOST}:${port}${HEALTH_PATH}")"
    r="$(http_code "http://${HEALTH_HOST}:${port}${READYZ_PATH}")"
    if [ "$h" = "200" ] && [ "$r" = "200" ]; then
      log "$color is healthy (/health=200, /readyz=200)."
      return 0
    fi
    log "  $color /health=$h /readyz=$r; waiting..."
    sleep 2
  done
  err "$color did not become healthy within ${HEALTH_TIMEOUT}s."
  return 1
}

# drain_color <color> <port> — POST /v1/admin/drain then poll /readyz inflight==0.
drain_color() {
  local color="$1" port="$2"
  log "Draining $color (port $port): POST $DRAIN_PATH, then poll $READYZ_PATH inflight==0..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would POST $DRAIN_PATH to $color:$port and poll inflight==0 (timeout ${DRAIN_TIMEOUT}s)"
    return 0
  fi
  # Phase 1 contract: admin-authenticated drain endpoint.
  if ! "$CURL_BIN" -fsS -X POST \
        -H "Authorization: Bearer ${EIGENINFERENCE_ADMIN_KEY:-}" \
        --max-time 10 \
        "http://${HEALTH_HOST}:${port}${DRAIN_PATH}" >/dev/null; then
    warn "drain request to $color returned an error (continuing to poll readiness)"
  fi
  local now deadline body inflight
  now="$(date +%s)"
  deadline=$(( now + DRAIN_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$("$CURL_BIN" -fsS --max-time 5 "http://${HEALTH_HOST}:${port}${READYZ_PATH}" 2>/dev/null || true)"
    # Phase 1 contract: /readyz exposes an inflight counter, e.g. {"inflight":0}.
    inflight="$(printf '%s' "$body" | sed -n 's/.*"inflight"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
    if [ -n "$inflight" ] && [ "$inflight" -eq 0 ]; then
      log "$color drained (inflight=0)."
      return 0
    fi
    log "  $color inflight=${inflight:-unknown}; waiting..."
    sleep 3
  done
  warn "$color did not reach inflight==0 within ${DRAIN_TIMEOUT}s; the graceful container stop (docker stop -t) will finish remaining requests."
  return 0
}

# ===========================================================================
# Rollback
# ===========================================================================
do_rollback() {
  local cur_port cur_color target_color target_port
  cur_port="$(current_upstream_port "$CADDYFILE")" || die "could not read current upstream port from $CADDYFILE"
  cur_color="$(color_for_port "$cur_port")" || die "current upstream port $cur_port is not a known color"
  target_color="$(other_color "$cur_color")"
  target_port="$(port_for_color "$target_color")"
  log "ROLLBACK: Caddy currently -> $cur_color ($cur_port); reverting to $target_color ($target_port)."
  warn "Rollback only restores routing. The $target_color container must still be RUNNING (valid only before it was stopped)."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would flip_upstream $CADDYFILE $cur_port $target_port, then reload Caddy."
    return 0
  fi
  confirm "Flip Caddy upstream $cur_port -> $target_port and reload?" || { log "Rollback aborted."; return 1; }
  flip_upstream "$CADDYFILE" "$cur_port" "$target_port" || die "flip_upstream failed (rc $?)"
  reload_caddy || die "caddy reload failed after rollback flip"
  log "ROLLBACK complete: Caddy -> $target_color ($target_port)."
}

# ===========================================================================
# CLI
# ===========================================================================
usage_main() {
  cat <<'USAGE'
Usage: deploy.sh [options]

Blue-green coordinator deploy on the GCE box. Detects the active color from the
Caddy upstream, brings up the idle color, cuts over, drains, and stops the old.

Options:
  --image <ref>      Pin this container image for the idle color before starting.
  --caddyfile <path> Caddyfile to read/flip (default: /etc/caddy/Caddyfile).
  --rollback         Flip Caddy back to the other (still-running) color + reload.
  --dry-run          Print the plan; change nothing.
  -y, --yes          Assume "yes" to all confirmation prompts (non-interactive).
  -h, --help         Show this help.

Environment overrides: CADDYFILE, BLUE_PORT(8080), GREEN_PORT(8081), HEALTH_HOST,
HEALTH_TIMEOUT, DRAIN_TIMEOUT, CADDY_BIN, SYSTEMCTL_BIN, CURL_BIN, DINF_DEPLOY_ENV.
USAGE
}

main() {
  set -uo pipefail

  DRY_RUN=0
  ROLLBACK=0
  ASSUME_YES=0
  IMAGE_REF=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --rollback) ROLLBACK=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --image) [ "$#" -ge 2 ] || { err "--image requires a value"; return 2; }; IMAGE_REF="$2"; shift ;;
      --image=*) IMAGE_REF="${1#*=}" ;;
      --caddyfile) [ "$#" -ge 2 ] || { err "--caddyfile requires a value"; return 2; }; CADDYFILE="$2"; shift ;;
      --caddyfile=*) CADDYFILE="${1#*=}" ;;
      -h|--help) usage_main; return 0 ;;
      *) err "unknown argument: $1"; usage_main; return 2 ;;
    esac
    shift
  done

  CADDYFILE="${CADDYFILE:-$CADDYFILE_DEFAULT}"
  [ -f "$CADDYFILE" ] || die "Caddyfile not found: $CADDYFILE (use --caddyfile or set CADDYFILE)"

  if [ "$ROLLBACK" -eq 1 ]; then
    do_rollback
    return $?
  fi

  local active_port active_color idle_color idle_port
  active_port="$(current_upstream_port "$CADDYFILE")" || die "could not detect active upstream port in $CADDYFILE"
  active_color="$(color_for_port "$active_port")" || die "active upstream port $active_port is neither blue($BLUE_PORT) nor green($GREEN_PORT)"
  idle_color="$(other_color "$active_color")"
  idle_port="$(port_for_color "$idle_color")"

  log "=============================================================="
  log " Blue-green deploy plan"
  log "   Caddyfile      : $CADDYFILE"
  log "   Active (live)  : $active_color (port $active_port)"
  log "   Idle  (target) : $idle_color (port $idle_port)"
  [ -n "$IMAGE_REF" ] && log "   New image      : $IMAGE_REF"
  [ "$DRY_RUN" -eq 1 ] && log "   MODE           : DRY-RUN (no changes will be made)"
  log "=============================================================="

  # 1. Pin image for the idle color (optional).
  if [ -n "$IMAGE_REF" ]; then
    pin_image "$IMAGE_REF"
  fi

  # 2. Start the idle color.
  confirm "Start idle color '$idle_color'?" || die "aborted before starting idle color"
  run_cmd "$SYSTEMCTL_BIN" start "darkbloom-coordinator@${idle_color}"

  # 3. Wait for idle health + readiness.
  if ! wait_healthy "$idle_color" "$idle_port"; then
    err "Idle color $idle_color failed health check; stopping it. Caddy untouched ($active_color still live)."
    run_cmd "$SYSTEMCTL_BIN" stop "darkbloom-coordinator@${idle_color}"
    die "deploy aborted: idle color unhealthy"
  fi

  # 4. Cutover: flip Caddy upstream active->idle + graceful reload (DESTRUCTIVE).
  if ! confirm "CUTOVER: flip Caddy $active_port -> $idle_port (live traffic to $idle_color) and reload?"; then
    err "Cutover declined; stopping idle color. Caddy still -> $active_color."
    run_cmd "$SYSTEMCTL_BIN" stop "darkbloom-coordinator@${idle_color}"
    die "deploy aborted before cutover"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would flip_upstream $CADDYFILE $active_port $idle_port, then reload Caddy."
  else
    flip_upstream "$CADDYFILE" "$active_port" "$idle_port" || die "flip_upstream failed (rc $?); Caddy unchanged, $active_color still live"
    if ! reload_caddy; then
      err "caddy reload failed after flip; attempting automatic rollback flip."
      flip_upstream "$CADDYFILE" "$idle_port" "$active_port" || err "rollback flip ALSO failed — manual intervention required on $CADDYFILE"
      reload_caddy || true
      die "deploy aborted: caddy reload failed (attempted rollback to $active_color)"
    fi
  fi
  log "Cutover complete: Caddy -> $idle_color ($idle_port). $active_color still running for drain."
  log "Rollback window OPEN: run '$0 --rollback' to revert to $active_color (valid until it is stopped)."

  # 5. Drain the old color.
  drain_color "$active_color" "$active_port"

  # 6. Stop the old color (closes rollback window; triggers Phase 3 going_away).
  if ! confirm "Stop old color '$active_color'? (closes rollback window; triggers Phase 3 going_away broadcast)"; then
    warn "Old color $active_color left RUNNING. Stop later with: $SYSTEMCTL_BIN stop darkbloom-coordinator@${active_color}"
    log "Deploy finished (old color intentionally not stopped)."
    return 0
  fi
  run_cmd "$SYSTEMCTL_BIN" stop "darkbloom-coordinator@${active_color}"
  log "Old color $active_color stopped. Deploy complete: $idle_color is now the sole live coordinator."
}

# Only auto-run when executed directly — NEVER when sourced (e.g. by the test).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
