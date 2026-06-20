#!/usr/bin/env bash
# deploy.sh — DAR-327 Phase 2: true blue-green coordinator deploy orchestrator.
#
# Runs ON the GCE coordinator box. Performs a zero-downtime color swap. Providers
# are moved to the new color BEFORE the old color is drained/stopped, so the new
# color never serves consumers with zero providers (which would 429):
#
#   1. detect the active color from the on-box Caddyfile upstream port
#   2. (optional) pin the new image in the idle color's per-color env file
#      (rolled back if the deploy is aborted before cutover; kept once accepted)
#   3. restart the IDLE color         (systemctl restart darkbloom-coordinator@<idle>)
#      — restart, NOT start, so a stale idle container re-execs with the new image
#   4. wait for idle /health AND /readyz  (DAR-327 Phase 1 endpoints)
#   5. flip the Caddy upstream old->new + graceful `caddy reload`  (cutover)
#   6. POST /v1/admin/going-away to the OLD color (DAR-327 Phase 3, PR #396) so its
#      providers reconnect and — Caddy already flipped — land on the NEW color
#   7. wait until the NEW color reports routable capacity>0 (providers landed + trusted)
#   8. drain the OLD color            (POST /v1/admin/drain, Phase 1) until inflight==0
#   9. stop the OLD color             (systemctl stop darkbloom-coordinator@<old>)
#
# Steps 6-7 explicitly hand providers to the new color via the Phase 3
# going-away endpoint; the drain (8) and stop (9) then retire the old color with
# no capacity gap. If providers do not land on the new color, or if the drain
# does not complete, the old color is NOT drained/stopped unless --force is given.
#
# ROLLBACK (valid any time AFTER the flip and BEFORE the old color is stopped):
#   ./deploy.sh --rollback
# restores BOTH routing AND capacity to the previous color. A bare Caddy flip is
# NOT sufficient once the forward deploy has signalled going-away to the old color:
# that latches the old color to REFUSE new provider registrations (503) and pushes
# its providers one-way onto the new color, so flipping back alone would route
# consumers to a color with no providers (429). Rollback therefore (1) re-enables
# the target color (undrain + clear its going-away latch so it accepts providers
# again), (2) flips the Caddy upstream back to it and reloads (restoring the
# on-disk Caddyfile if the reload itself fails), (3) broadcasts going-away to the
# now-abandoned color so its providers reconnect and land back on the restored
# color, and (4) waits for the restored color to report routable capacity>0.
#
# SAFETY:
#   * --dry-run prints the full plan (new ordering) and mutates NOTHING.
#   * destructive steps require interactive confirmation (skip with -y/--yes).
#   * the Caddy port flip is the self-contained, unit-tested function
#     flip_upstream(); see deploy/gcp/prod/deploy_test.sh.
#   * sourcing this file (e.g. from the test) defines the functions but NEVER
#     runs main — see the BASH_SOURCE guard at the bottom.
#   * the ONLY secret touched here is EIGENINFERENCE_ADMIN_KEY: it is PARSED (a
#     single grep'd line — never `source`d/`.`d) from /etc/d-inference/env
#     (Secret Manager -> tmpfs -> --env-file) at cutover time to authenticate the
#     admin going-away/drain POSTs. That file is docker --env-file syntax, NOT
#     shell: sourcing it would execute secret values (e.g. the 12-word MNEMONIC,
#     '&'/URL chars) as shell commands AS ROOT, so we never source it. The key is
#     never printed or written, and is NOT read in --dry-run. All other
#     coordinator secrets stay in that file and are never touched here.
#
# Cross-phase contracts (separate PRs; referenced, not implemented here):
#   Phase 1 : GET /readyz  +  POST /v1/admin/drain  (bodyless POST = start draining;
#             POST {"draining":false} = clear the drain latch / undrain)
#   Phase 3 : POST /v1/admin/going-away (admin-gated). Empty body = broadcast+latch,
#             returns 200 {"sent":N}.  {"cancel":true} = clear the latch,
#             returns 200 {"going_away":false,"cleared":true}.

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
CAPACITY_PATH="${CAPACITY_PATH:-/v1/models/capacity}"
# Phase 3 (PR #396) endpoint: tells the OLD color's providers to reconnect so
# they re-land on the already-flipped NEW color. Admin-gated; returns {"sent":N}.
GOING_AWAY_PATH="${GOING_AWAY_PATH:-/v1/admin/going-away}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"
# How long to wait for the NEW color to report routable capacity>0 after going-away.
PROVIDERS_TIMEOUT="${PROVIDERS_TIMEOUT:-60}"
CADDY_BIN="${CADDY_BIN:-caddy}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
CURL_BIN="${CURL_BIN:-curl}"
DINF_DEPLOY_ENV_TMPL="${DINF_DEPLOY_ENV_TMPL:-/etc/d-inference/deploy-%s.env}"
# Secrets env file (Secret Manager -> tmpfs). Holds EIGENINFERENCE_ADMIN_KEY,
# whose single line is PARSED (never sourced; see load_admin_env) at cutover time
# to authenticate the admin going-away/drain POSTs. Distinct from the non-secret
# per-color DINF_DEPLOY_ENV_TMPL image-pin files above. Overridable for tests.
DINF_ENV_FILE="${DINF_ENV_FILE:-/etc/d-inference/env}"

# Runtime flags (main overrides from CLI args).
DRY_RUN="${DRY_RUN:-0}"
ROLLBACK=0
ASSUME_YES=0
FORCE=0
IMAGE_REF=""

# Image-pin rollback state (set by pin_image, consumed by restore/accept).
# DINF_DEPLOY_ENV_BAK="" means "no pin to roll back"; DINF_DEPLOY_ENV_PINNED
# keeps restore/accept pointed at the exact per-color file pin_image touched.
DINF_DEPLOY_ENV_BAK=""
DINF_DEPLOY_ENV_EXISTED=0
DINF_DEPLOY_ENV_PINNED=""

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

deploy_env_for_color() {
  if [ "$#" -ne 1 ]; then
    echo "deploy_env_for_color: usage: deploy_env_for_color <blue|green>" >&2
    return 2
  fi
  local color="$1"
  case "$color" in
    blue|green) ;;
    *) echo "deploy_env_for_color: unknown color: $color" >&2; return 2 ;;
  esac
  case "$DINF_DEPLOY_ENV_TMPL" in
    *%s*) printf '%s\n' "${DINF_DEPLOY_ENV_TMPL/\%s/$color}" ;;
    *) echo "deploy_env_for_color: DINF_DEPLOY_ENV_TMPL must contain %s: $DINF_DEPLOY_ENV_TMPL" >&2; return 2 ;;
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

# pin_image <color> <ref> — write DINF_IMAGE=<ref> to the idle color's per-color
# deploy env file so only that color re-execs with the new image. The previous
# pin state is snapshotted first so restore_image_pin can undo it if the deploy
# is aborted BEFORE the cutover is accepted. The pin is made permanent by
# accept_image_pin once the cutover succeeds.
pin_image() {
  if [ "$#" -ne 2 ]; then
    echo "pin_image: usage: pin_image <blue|green> <image-ref>" >&2
    return 2
  fi
  local color="$1" ref="$2" pin_file
  pin_file="$(deploy_env_for_color "$color")" || return $?
  log "Pinning $color image: DINF_IMAGE=$ref -> $pin_file"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would snapshot $pin_file, then write DINF_IMAGE=$ref (read by darkbloom-run.sh via EnvironmentFile); the pin is rolled back if the deploy aborts before cutover, kept once cutover is accepted"
    return 0
  fi
  local dir bak tmp rc
  dir="$(dirname "$pin_file")"
  if ! mkdir -p "$dir"; then
    err "failed to create deploy env directory $dir"
    return 1
  fi
  # Snapshot the current pin so an aborted/declined/unhealthy deploy can restore
  # it. An empty backup with DINF_DEPLOY_ENV_EXISTED=0 marks "file did not exist".
  bak="$(mktemp)" || { err "mktemp failed"; return 1; }
  if [ -f "$pin_file" ]; then
    if ! cat "$pin_file" > "$bak"; then
      rm -f "$bak"
      err "failed to snapshot existing image pin $pin_file"
      return 1
    fi
    DINF_DEPLOY_ENV_EXISTED=1
  else
    DINF_DEPLOY_ENV_EXISTED=0
  fi
  DINF_DEPLOY_ENV_BAK="$bak"
  DINF_DEPLOY_ENV_PINNED="$pin_file"

  tmp="$(mktemp)" || { err "mktemp failed"; return 1; }
  if [ -f "$pin_file" ]; then
    grep -v '^DINF_IMAGE=' "$pin_file" > "$tmp"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      rm -f "$tmp"
      err "failed to read existing image pin $pin_file"
      return 1
    fi
  fi
  if ! printf 'DINF_IMAGE=%s\n' "$ref" >> "$tmp"; then
    rm -f "$tmp"
    err "failed to write temporary image pin for $pin_file"
    return 1
  fi
  if ! cat "$tmp" > "$pin_file"; then
    rm -f "$tmp"
    err "failed to write image pin $pin_file"
    return 1
  fi
  rm -f "$tmp"
  if ! chmod 644 "$pin_file"; then
    err "failed to chmod image pin $pin_file"
    return 1
  fi
}

# restore_image_pin — undo a pin_image() write. Called on any exit BEFORE the
# cutover is accepted (via the EXIT trap in main). No-op if nothing was pinned or
# the pin was already accepted (accept_image_pin clears the backup).
restore_image_pin() {
  [ -n "${DINF_DEPLOY_ENV_BAK:-}" ] || return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local pin_file="${DINF_DEPLOY_ENV_PINNED:-}"
  if [ -z "$pin_file" ]; then
    warn "Deploy aborted before cutover, but no pinned deploy env path was recorded; cannot restore image pin."
    rm -f "$DINF_DEPLOY_ENV_BAK"
    DINF_DEPLOY_ENV_BAK=""
    return 0
  fi
  if [ "${DINF_DEPLOY_ENV_EXISTED:-0}" -eq 1 ]; then
    warn "Deploy aborted before cutover: restoring previous image pin in $pin_file."
    cat "$DINF_DEPLOY_ENV_BAK" > "$pin_file" 2>/dev/null || warn "failed to restore $pin_file"
    chmod 644 "$pin_file" 2>/dev/null || true
  else
    warn "Deploy aborted before cutover: removing image pin $pin_file (created this run)."
    rm -f "$pin_file" 2>/dev/null || warn "failed to remove $pin_file"
  fi
  rm -f "$DINF_DEPLOY_ENV_BAK"
  DINF_DEPLOY_ENV_BAK=""
  DINF_DEPLOY_ENV_PINNED=""
}

# accept_image_pin — keep the pin permanently (cutover succeeded) and disarm the
# restore_image_pin rollback by dropping the backup.
accept_image_pin() {
  [ -n "${DINF_DEPLOY_ENV_BAK:-}" ] || return 0
  rm -f "$DINF_DEPLOY_ENV_BAK"
  DINF_DEPLOY_ENV_BAK=""
  DINF_DEPLOY_ENV_PINNED=""
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

# load_admin_env — read ONLY the EIGENINFERENCE_ADMIN_KEY line from the secrets
# env file into the global of the same name, for the authenticated going-away +
# drain requests.
#
# SECURITY: that file is docker --env-file syntax (KEY=VALUE), NOT shell. Sourcing
# it (`.`/`source`) would execute values — the 12-word MNEMONIC, '&', URL/`$()`
# chars — as shell commands AS ROOT (secret leak / RCE). So we never source it; we
# grep the single line and strip optional surrounding quotes. No eval, no source.
# The value is never printed. Called only at real cutover time (after the
# --dry-run early returns) so the plan stays secret-free. No-op + warning if the
# file is absent/unreadable (caller still warns on empty key and continues).
load_admin_env() {
  if [ -r "$DINF_ENV_FILE" ]; then
    # First match wins; cut -f2- keeps '=' chars in the value; 2>/dev/null + the
    # lack of `set -e` make a no-match safely yield an empty key.
    EIGENINFERENCE_ADMIN_KEY="$(grep -E '^EIGENINFERENCE_ADMIN_KEY=' "$DINF_ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)"
    # Strip one pair of surrounding quotes if the value is quoted in the env file.
    case "$EIGENINFERENCE_ADMIN_KEY" in
      '"'*'"') EIGENINFERENCE_ADMIN_KEY="${EIGENINFERENCE_ADMIN_KEY#\"}"; EIGENINFERENCE_ADMIN_KEY="${EIGENINFERENCE_ADMIN_KEY%\"}" ;;
      "'"*"'") EIGENINFERENCE_ADMIN_KEY="${EIGENINFERENCE_ADMIN_KEY#\'}"; EIGENINFERENCE_ADMIN_KEY="${EIGENINFERENCE_ADMIN_KEY%\'}" ;;
    esac
  else
    warn "secrets env file not readable at $DINF_ENV_FILE; admin key unavailable for going-away/drain auth"
  fi
}

# drain_color <color> <port> — POST /v1/admin/drain then poll /readyz inflight==0.
# Returns 0 once inflight==0, NON-ZERO on timeout so the caller does NOT stop a
# color that still has in-flight requests (stopping would cut them at the SIGTERM
# deadline). EIGENINFERENCE_ADMIN_KEY is loaded once by the caller (load_admin_env).
drain_color() {
  local color="$1" port="$2"
  log "Draining $color (port $port): POST $DRAIN_PATH, then poll $READYZ_PATH inflight==0..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would POST $DRAIN_PATH to $color:$port and poll inflight==0 (timeout ${DRAIN_TIMEOUT}s)"
    return 0
  fi
  # Phase 1 contract: admin-authenticated drain endpoint. The bearer key was
  # parsed (not sourced) from the env file by the caller's load_admin_env.
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
  err "$color did not reach inflight==0 within ${DRAIN_TIMEOUT}s."
  return 1
}

# undrain_color <color> <port> — POST /v1/admin/drain {"draining":false} to CLEAR a
# color's drain latch so it re-accepts work (the inverse of drain_color's bodyless
# POST, which STARTS draining). Used by --rollback to re-enable the rollback target,
# which the forward deploy may have drained. Best-effort: warns and continues on any
# failure so a not-yet-deployed endpoint degrades gracefully. DRY_RUN-aware.
# EIGENINFERENCE_ADMIN_KEY is loaded once by the caller (load_admin_env).
undrain_color() {
  local color="$1" port="$2"
  log "Undraining $color (port $port): POST $DRAIN_PATH {\"draining\":false} (re-accept work)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would POST $DRAIN_PATH {\"draining\":false} to $color:$port"
    return 0
  fi
  # Phase 1 contract: the drain endpoint accepts {"draining":false} to UN-drain.
  if ! "$CURL_BIN" -fsS -X POST \
        -H "Authorization: Bearer ${EIGENINFERENCE_ADMIN_KEY:-}" \
        -H "Content-Type: application/json" \
        --max-time 10 \
        --data '{"draining":false}' \
        "http://${HEALTH_HOST}:${port}${DRAIN_PATH}" >/dev/null; then
    warn "undrain request to $color returned an error (continuing; it may already accept work, or the endpoint is not deployed yet)."
  else
    log "$color undrained (now re-accepting work)."
  fi
}

# signal_going_away <color> <port> — POST /v1/admin/going-away to the OLD color so
# its providers reconnect and (Caddy already flipped) re-land on the NEW color.
# Phase 3 (PR #396) contract: admin-gated, returns 200 {"sent":N}. Best-effort:
# warns and continues if it fails (providers still reconnect within the heartbeat
# timeout, and the drain + graceful stop still finish in-flight work).
# EIGENINFERENCE_ADMIN_KEY is loaded once by the caller (load_admin_env).
signal_going_away() {
  local color="$1" port="$2"
  log "Going-away to OLD color $color (port $port): POST $GOING_AWAY_PATH (providers reconnect -> new color)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would POST $GOING_AWAY_PATH to $color:$port (admin-gated; expect 200 {\"sent\":N})"
    return 0
  fi
  local body sent
  body="$("$CURL_BIN" -fsS -X POST \
        -H "Authorization: Bearer ${EIGENINFERENCE_ADMIN_KEY:-}" \
        --max-time 10 \
        "http://${HEALTH_HOST}:${port}${GOING_AWAY_PATH}" 2>/dev/null || true)"
  # Contract response: {"sent":N}.
  sent="$(printf '%s' "$body" | sed -n 's/.*"sent"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  if [ -n "$sent" ]; then
    log "going-away accepted by $color (sent=$sent; those providers will reconnect to the new color)."
  else
    warn "going-away to $color did not return a parseable {\"sent\":N} (continuing; providers will still reconnect within the heartbeat timeout)."
  fi
}

# clear_going_away <color> <port> — POST /v1/admin/going-away {"cancel":true} to
# CLEAR a color's going-away latch (set by a prior signal_going_away). Until cleared
# that latch makes the color REFUSE new provider registrations (503), so --rollback
# MUST clear it on the rollback target before flipping traffic back, or the restored
# color would route consumers to zero providers. Phase 3 (PR #396) contract:
# admin-gated; empty body = broadcast+latch (signal_going_away), {"cancel":true} =
# clear, returns 200 {"going_away":false,"cleared":true}. Best-effort: warns and
# continues on failure (a not-yet-deployed endpoint degrades gracefully).
# DRY_RUN-aware. EIGENINFERENCE_ADMIN_KEY is loaded once by the caller (load_admin_env).
clear_going_away() {
  local color="$1" port="$2"
  log "Clearing going-away latch on $color (port $port): POST $GOING_AWAY_PATH {\"cancel\":true} (re-accept providers)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would POST $GOING_AWAY_PATH {\"cancel\":true} to $color:$port (admin-gated; expect 200 {\"going_away\":false,\"cleared\":true})"
    return 0
  fi
  local body cleared
  body="$("$CURL_BIN" -fsS -X POST \
        -H "Authorization: Bearer ${EIGENINFERENCE_ADMIN_KEY:-}" \
        -H "Content-Type: application/json" \
        --max-time 10 \
        --data '{"cancel":true}' \
        "http://${HEALTH_HOST}:${port}${GOING_AWAY_PATH}" 2>/dev/null || true)"
  # Contract response: {"going_away":false,"cleared":true}.
  cleared="$(printf '%s' "$body" | sed -n 's/.*"cleared"[[:space:]]*:[[:space:]]*true.*/true/p' | head -n1)"
  if [ "$cleared" = "true" ]; then
    log "going-away latch cleared on $color (now re-accepts provider registrations)."
  else
    warn "clear going-away on $color did not confirm {\"cleared\":true} (continuing; endpoint may not be deployed yet — providers will still re-register once it accepts them)."
  fi
}

# capacity_model_count reads GET /v1/models/capacity JSON from stdin and prints the
# number of routable capacity entries. Empty/malformed bodies produce 0. Uses
# python3 instead of jq because the GCE deploy box already relies on python3 in
# darkbloom-run.sh for registry auth, while jq may not be installed.
capacity_model_count() {
  python3 -c 'import json,sys
try:
    body=json.load(sys.stdin)
    print(len(body.get("models") or []))
except Exception:
    print(0)'
}

# wait_for_providers <color> <port> — after going-away, poll the NEW color's
# routable capacity feed until at least one model has capacity. Raw /health
# providers only proves a WebSocket registered; /v1/models/capacity proves the
# provider is trusted/routable enough for consumers. Returns nonzero on timeout.
wait_for_providers() {
  local color="$1" port="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would poll http://${HEALTH_HOST}:${port}${CAPACITY_PATH} for routable capacity>0 (timeout ${PROVIDERS_TIMEOUT}s)"
    return 0
  fi
  log "Waiting for $color (port $port) to report routable capacity>0 via $CAPACITY_PATH (timeout ${PROVIDERS_TIMEOUT}s)..."
  local now deadline body count
  now="$(date +%s)"
  deadline=$(( now + PROVIDERS_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$($CURL_BIN -fsS --max-time 5 "http://${HEALTH_HOST}:${port}${CAPACITY_PATH}" 2>/dev/null || true)"
    count="$(printf '%s' "$body" | capacity_model_count)"
    if [ -n "$count" ] && [ "$count" -gt 0 ]; then
      log "$color now has $count routable capacity entr(ies)."
      return 0
    fi
    log "  $color routable_capacity=${count:-0}; waiting for trusted/routable providers..."
    sleep 2
  done
  warn "$color did not report routable capacity>0 within ${PROVIDERS_TIMEOUT}s; providers may still be reconnecting/attesting."
  return 1
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
  log "Rollback restores routing AND capacity: re-enable $target_color (undrain + clear its going-away latch), flip Caddy back, then push providers off $cur_color back onto $target_color."
  warn "The $target_color container must still be RUNNING (rollback is valid only before it was stopped)."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would health-check $target_color at http://${HEALTH_HOST}:${target_port}${HEALTH_PATH} before flipping."
    log "DRY-RUN: would load_admin_env (parse EIGENINFERENCE_ADMIN_KEY for the admin POSTs below)."
    log "DRY-RUN: STEP A — would re-enable $target_color: POST $DRAIN_PATH {\"draining\":false} (undrain) + POST $GOING_AWAY_PATH {\"cancel\":true} (clear going-away latch) to ${HEALTH_HOST}:${target_port}."
    log "DRY-RUN: STEP B — would flip_upstream $CADDYFILE $cur_port $target_port, then reload Caddy (auto-revert to $cur_color if reload fails)."
    log "DRY-RUN: STEP C — would POST $GOING_AWAY_PATH to the now-abandoned $cur_color ($cur_port) so its providers reconnect and land on $target_color."
    log "DRY-RUN: STEP D — would poll $target_color ($target_port) $CAPACITY_PATH for routable capacity>0 (timeout ${PROVIDERS_TIMEOUT}s)."
    log "DRY-RUN: would leave $cur_color running (idle, providers drained off) for inspection; stop it manually with '$SYSTEMCTL_BIN stop darkbloom-coordinator@${cur_color}'."
    return 0
  fi
  # Never flip onto a dead port (connection refused -> 502s): probe the target's
  # liveness BEFORE flipping. Single-shot http_code (not the up-to-${HEALTH_TIMEOUT}s
  # wait_healthy poll) so a dead target is refused fast. /health is liveness only:
  # a drained-but-running old color stays rollback-able even if /readyz is not 200.
  local target_health
  target_health="$(http_code "http://${HEALTH_HOST}:${target_port}${HEALTH_PATH}")"
  if [ "$target_health" = "200" ]; then
    log "Rollback target $target_color (port $target_port) is alive (/health=200)."
  elif [ "$FORCE" -eq 1 ]; then
    warn "!!! Rollback target $target_color (port $target_port) is NOT healthy (/health=$target_health); proceeding anyway because --force was given — traffic may hit a dead port (502s) !!!"
  else
    err "Rollback target $target_color (port $target_port) is NOT healthy (/health=$target_health)."
    err "Refusing to flip Caddy onto a dead/unhealthy port (would cause 502s)."
    err "Start it first (e.g. '$SYSTEMCTL_BIN start darkbloom-coordinator@${target_color}'), or re-run with --force to flip anyway."
    return 1
  fi
  confirm "Roll back to $target_color: re-enable it, flip Caddy $cur_port -> $target_port, and push providers back?" || { log "Rollback aborted."; return 1; }

  # Parse the admin key for the authenticated undrain + going-away POSTs below. Real
  # run only — the --dry-run path returned above, so the plan stays secret-free.
  load_admin_env
  if [ -z "${EIGENINFERENCE_ADMIN_KEY:-}" ]; then
    warn "EIGENINFERENCE_ADMIN_KEY is empty ($DINF_ENV_FILE missing or unset); the undrain/going-away POSTs will be unauthenticated and likely rejected — continuing (best-effort)."
  fi

  # STEP A — re-enable the rollback target BEFORE flipping traffic onto it. The
  # forward deploy latched it going-away (it now refuses new provider registrations,
  # 503) and may have drained it; undo BOTH so it can re-accept providers once Caddy
  # points back at it. Best-effort (warn + continue) so a not-yet-deployed Phase 1/3
  # endpoint degrades gracefully.
  undrain_color "$target_color" "$target_port"
  clear_going_away "$target_color" "$target_port"

  # STEP B — flip Caddy cur->target + reload. Mirror the cutover path: if the reload
  # fails after flipping the on-disk Caddyfile, flip it BACK so on-disk state matches
  # live Caddy (still -> $cur_color); otherwise a later run would read the stale
  # on-disk port and flip/stop the wrong color.
  flip_upstream "$CADDYFILE" "$cur_port" "$target_port" || die "flip_upstream failed (rc $?)"
  if ! reload_caddy; then
    err "caddy reload failed after rollback flip; restoring Caddyfile to $cur_color ($cur_port) so on-disk state matches live Caddy."
    flip_upstream "$CADDYFILE" "$target_port" "$cur_port" || err "restore flip ALSO failed — manual intervention required on $CADDYFILE"
    reload_caddy || true
    die "rollback aborted: caddy reload failed (Caddyfile restored to $cur_color)"
  fi
  log "Caddy now -> $target_color ($target_port)."

  # STEP C — push providers off the now-abandoned $cur_color back onto $target_color.
  # Broadcast going-away to $cur_color: its providers reconnect and — Caddy already
  # flipped — land on $target_color. (signal_going_away logs this as the "OLD" color;
  # in a rollback that is the abandoned new color we are retiring.) Best-effort like
  # the forward path; providers also reconnect within the heartbeat timeout.
  log "Pushing providers off the abandoned $cur_color back onto $target_color..."
  signal_going_away "$cur_color" "$cur_port"

  # STEP D — confirm routable capacity actually returned to $target_color. If it
  # does not, restore routing to the previously-live $cur_color rather than
  # declaring rollback success on a provider-empty target.
  if ! wait_for_providers "$target_color" "$target_port"; then
    warn "Rollback target $target_color did not regain routable capacity; restoring Caddy back to $cur_color."
    undrain_color "$cur_color" "$cur_port"
    clear_going_away "$cur_color" "$cur_port"
    flip_upstream "$CADDYFILE" "$target_port" "$cur_port" || die "rollback recovery failed: could not flip Caddy back to $cur_color ($cur_port); manual intervention required"
    if ! reload_caddy; then
      die "rollback recovery failed: Caddy reload back to $cur_color ($cur_port) failed; manual intervention required"
    fi
    signal_going_away "$target_color" "$target_port"
    wait_for_providers "$cur_color" "$cur_port" || warn "Previously-live $cur_color did not confirm routable capacity after rollback recovery; monitor capacity immediately."
    die "rollback aborted: providers did not return to $target_color; Caddy restored to $cur_color"
  fi

  log "ROLLBACK complete: Caddy -> $target_color ($target_port); providers pushed back to it."
  log "The abandoned $cur_color ($cur_port) is left RUNNING (idle, providers drained off) for inspection; stop it manually with '$SYSTEMCTL_BIN stop darkbloom-coordinator@${cur_color}'."
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
  --rollback         Roll back to the other (still-running) color: re-enable it
                     (undrain + clear its going-away latch), flip Caddy back +
                     reload, then push providers back onto it and wait for
                     routable capacity>0.
  --force            Forward: continue drain/stop even if providers do not land or
                     drain times out. Rollback: flip even if target health fails
                     (DANGEROUS — may route traffic to a dead port).
  --dry-run          Print the plan; change nothing.
  -y, --yes          Assume "yes" to all confirmation prompts (non-interactive).
  -h, --help         Show this help.

Environment overrides: CADDYFILE, BLUE_PORT(8080), GREEN_PORT(8081), HEALTH_HOST,
HEALTH_TIMEOUT, DRAIN_TIMEOUT, PROVIDERS_TIMEOUT(60), GOING_AWAY_PATH,
CAPACITY_PATH(/v1/models/capacity), CADDY_BIN, SYSTEMCTL_BIN, CURL_BIN,
DINF_DEPLOY_ENV_TMPL(/etc/d-inference/deploy-%s.env), DINF_ENV_FILE(/etc/d-inference/env).
USAGE
}

main() {
  set -uo pipefail

  DRY_RUN=0
  ROLLBACK=0
  ASSUME_YES=0
  FORCE=0
  IMAGE_REF=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --rollback) ROLLBACK=1 ;;
      --force) FORCE=1 ;;
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

  local active_port active_color idle_color idle_port image_pin_file
  active_port="$(current_upstream_port "$CADDYFILE")" || die "could not detect active upstream port in $CADDYFILE"
  active_color="$(color_for_port "$active_port")" || die "active upstream port $active_port is neither blue($BLUE_PORT) nor green($GREEN_PORT)"
  idle_color="$(other_color "$active_color")"
  idle_port="$(port_for_color "$idle_color")"
  if [ -n "$IMAGE_REF" ]; then
    image_pin_file="$(deploy_env_for_color "$idle_color")" || die "could not compute deploy env path for idle color $idle_color"
  fi

  log "=============================================================="
  log " Blue-green deploy plan"
  log "   Caddyfile      : $CADDYFILE"
  log "   Active (live)  : $active_color (port $active_port)"
  log "   Idle  (target) : $idle_color (port $idle_port)"
  [ -n "$IMAGE_REF" ] && log "   New image      : $IMAGE_REF"
  [ -n "$IMAGE_REF" ] && log "   Image pin file : $image_pin_file"
  [ "$DRY_RUN" -eq 1 ] && log "   MODE           : DRY-RUN (no changes will be made)"
  log "=============================================================="

  # Roll the image pin back automatically on ANY exit before the cutover is
  # accepted (declined confirm, failed start, unhealthy idle, failed flip/reload).
  # accept_image_pin() disarms this once the cutover succeeds. No-op without --image.
  trap 'restore_image_pin' EXIT

  # 1. Pin image for the idle color (optional). Snapshotted so it is rolled back
  #    if the deploy aborts before cutover.
  if [ -n "$IMAGE_REF" ]; then
    if ! pin_image "$idle_color" "$IMAGE_REF"; then
      die "deploy aborted: failed to pin image for idle color '$idle_color'; not restarting it"
    fi
  fi

  # 2. Restart the idle color. RESTART (not start) so a stale already-running idle
  #    container re-execs darkbloom-run.sh and picks up the newly pinned image.
  #    Check the rc and fail fast: a failed unit (re)start would otherwise only
  #    surface after wait_healthy times out (up to ${HEALTH_TIMEOUT}s).
  confirm "Restart idle color '$idle_color' (re-exec with the pinned image)?" || die "aborted before starting idle color"
  if ! run_cmd "$SYSTEMCTL_BIN" restart "darkbloom-coordinator@${idle_color}"; then
    die "failed to (re)start idle color '$idle_color' ($SYSTEMCTL_BIN restart darkbloom-coordinator@${idle_color} exited non-zero); Caddy untouched ($active_color still live). Inspect: $SYSTEMCTL_BIN status darkbloom-coordinator@${idle_color}"
  fi

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
  # Cutover accepted: the NEW color is live. Keep the image pin permanently and
  # disarm the EXIT-trap rollback.
  accept_image_pin
  log "Cutover complete: Caddy -> $idle_color ($idle_port). $active_color still running for drain."
  log "Rollback window OPEN: run '$0 --rollback' to revert to $active_color (valid until it is stopped)."

  # Parse the admin key ONCE (real run only; never in --dry-run so the plan stays
  # secret-free) for the authenticated going-away + drain POSTs below.
  if [ "$DRY_RUN" -ne 1 ]; then
    load_admin_env
    if [ -z "${EIGENINFERENCE_ADMIN_KEY:-}" ]; then
      warn "EIGENINFERENCE_ADMIN_KEY is empty ($DINF_ENV_FILE missing or unset); going-away and drain POSTs will be unauthenticated and likely rejected — continuing."
    fi
  fi

  # 5. Move providers to the NEW color BEFORE draining the old one: POST
  #    going-away to the OLD color so its providers reconnect and land on the
  #    (already-flipped) new color. Without this the new color would serve
  #    consumers with zero providers during the drain window (429s).
  signal_going_away "$active_color" "$active_port"

  # 6. Wait until the NEW color actually has routable capacity (reconnects landed
  #    and providers are trusted/routable). If this times out, do NOT drain/stop
  #    the old color unless --force is set: old providers have not proven they
  #    landed on the new color yet.
  if ! wait_for_providers "$idle_color" "$idle_port"; then
    if [ "$FORCE" -eq 1 ]; then
      warn "Routable capacity did not land on $idle_color within ${PROVIDERS_TIMEOUT}s, but --force was given; proceeding to drain/stop $active_color despite capacity risk."
    else
      err "NOT draining or stopping $active_color: $idle_color did not report routable capacity>0 within ${PROVIDERS_TIMEOUT}s."
      err "Restoring Caddy back to $active_color so production traffic returns to the known-capacity color."
      undrain_color "$active_color" "$active_port"
      clear_going_away "$active_color" "$active_port"
      flip_upstream "$CADDYFILE" "$idle_port" "$active_port" || die "provider handoff failed and Caddy restore flip back to $active_color failed; manual intervention required"
      if ! reload_caddy; then
        die "provider handoff failed and Caddy reload back to $active_color failed; manual intervention required"
      fi
      signal_going_away "$idle_color" "$idle_port"
      wait_for_providers "$active_color" "$active_port" || warn "$active_color did not confirm routable capacity after restore; monitor capacity immediately."
      die "deploy aborted: providers did not land on new color; Caddy restored to $active_color and $active_color left running"
    fi
  fi

  # 7. Drain the old color. If it does NOT drain in time, do NOT stop it (stopping
  #    would cut in-flight requests at the container SIGTERM deadline): abort with
  #    a nonzero exit (Caddy already -> new color, old color left running) unless
  #    --force is given.
  if ! drain_color "$active_color" "$active_port"; then
    if [ "$FORCE" -eq 1 ]; then
      warn "Drain of $active_color did not complete, but --force was given; proceeding to stop it (in-flight requests may be cut at the container SIGTERM deadline)."
    else
      err "NOT stopping $active_color: its drain did not reach inflight==0 within ${DRAIN_TIMEOUT}s."
      err "Caddy is already -> $idle_color; the old color stays RUNNING (rollback still possible)."
      err "Investigate, then stop manually ('$SYSTEMCTL_BIN stop darkbloom-coordinator@${active_color}'), or re-run with --force to stop despite in-flight requests."
      die "deploy aborted: old color drain incomplete (cutover done, $active_color left running)"
    fi
  fi

  # 8. Stop the old color (closes the rollback window). Fail if the stop fails:
  #    a still-running old color stays attached to providers and must not linger
  #    silently as if the deploy succeeded.
  if ! confirm "Stop old color '$active_color'? (closes rollback window)"; then
    warn "Old color $active_color left RUNNING. Stop later with: $SYSTEMCTL_BIN stop darkbloom-coordinator@${active_color}"
    log "Deploy finished (old color intentionally not stopped)."
    return 0
  fi
  if ! run_cmd "$SYSTEMCTL_BIN" stop "darkbloom-coordinator@${active_color}"; then
    die "failed to stop old color '$active_color' ($SYSTEMCTL_BIN stop darkbloom-coordinator@${active_color} exited non-zero); it may still be attached to providers — investigate: $SYSTEMCTL_BIN status darkbloom-coordinator@${active_color}"
  fi
  log "Old color $active_color stopped. Deploy complete: $idle_color is now the sole live coordinator."
}

# Only auto-run when executed directly — NEVER when sourced (e.g. by the test).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
