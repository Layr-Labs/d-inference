#!/usr/bin/env bash
# deploy_test.sh — infra-free unit tests for deploy.sh's pure functions
# (DAR-327 Phase 2). No Docker, systemd, Caddy, gcloud or network required.
#
# Sources deploy.sh (which, thanks to its BASH_SOURCE guard, defines functions
# without running main), writes a sample Caddyfile, and exercises flip_upstream
# and current_upstream_port: the upstream flips, is reversible and idempotent,
# and NO other line (step-ca :9000, MicroMDM :9002, internal :8090 listener) is
# mutated.
#
# Also covers two security/safety-critical helpers added in the Phase 2 review:
#   - load_admin_env: PARSES (never sources) the EIGENINFERENCE_ADMIN_KEY line,
#     incl. a regression canary proving env-file values are NOT executed.
#   - pin_image / restore_image_pin / accept_image_pin: the per-color image-pin
#     rollback so an aborted deploy never leaves the idle color on an unaccepted
#     image.
#
# Run:  ./deploy/gcp/prod/deploy_test.sh        (or: bash deploy/gcp/prod/deploy_test.sh)
# Exit: 0 if all assertions pass, 1 otherwise.

# Intentionally NOT `set -e`: flip_upstream returns 3 (no-op) by design and the
# idempotency test asserts on that non-zero return.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="${DEPLOY_SH:-${SCRIPT_DIR}/../../../deploy.sh}"

if [ ! -f "$DEPLOY_SH" ]; then
  echo "deploy_test: cannot find deploy.sh at $DEPLOY_SH" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$DEPLOY_SH"

PASS=0
FAIL=0
pass() { printf 'ok     - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'NOT OK - %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; FAIL=$((FAIL + 1)); }

assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
assert_rc() { # <desc> <expected_rc> <actual_rc>
  if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1" "expected rc $2 got $3"; fi
}
assert_contains() { # <desc> <file> <needle>
  if grep -qF "$3" "$2"; then pass "$1"; else fail "$1" "missing [$3] in $2"; fi
}
assert_absent() { # <desc> <file> <needle>
  if grep -qF "$3" "$2"; then fail "$1" "unexpected [$3] in $2"; else pass "$1"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ORIG="$WORK/Caddyfile.orig"
CF="$WORK/Caddyfile"

# Sample mirrors deploy/gcp/prod/Caddyfile: the snippet contains the step-ca
# (:9000) and MicroMDM (:9002) https upstreams, the /dl/* and
# /enroll.mobileconfig static handlers, and the single coordinator upstream
# (:8080), imported by two public sites and the internal :8090 listener.
cat > "$ORIG" <<'CADDY'
(coordinator_routes) {
	handle /acme/* {
		reverse_proxy https://127.0.0.1:9000 {
			transport http {
				tls_insecure_skip_verify
			}
			header_up Host {host}
		}
	}
	handle /mdm/* {
		reverse_proxy https://127.0.0.1:9002 {
			transport http {
				tls_insecure_skip_verify
			}
		}
	}
	handle /dl/* {
		root * /var/www/html
		file_server
	}
	handle /enroll.mobileconfig {
		root * /var/www/html
		file_server
	}
	reverse_proxy 127.0.0.1:8080 {
		health_uri /health
		health_interval 30s
	}
}

coord-staging.darkbloom.dev {
	import coordinator_routes
}

api.darkbloom.dev {
	tls /etc/caddy/certs/api.darkbloom.dev.crt /etc/caddy/certs/api.darkbloom.dev.key
	import coordinator_routes
}

http://127.0.0.1:8090 {
	import coordinator_routes
}
CADDY

cp "$ORIG" "$CF"

echo "# deploy_test: flip_upstream / current_upstream_port"

# ---- detect initial active port ----
port="$(current_upstream_port "$CF")"; rc=$?
assert_rc "current_upstream_port returns 0 on a valid file" 0 "$rc"
assert_eq "current_upstream_port reads 8080 initially" "8080" "$port"

# ---- flip 8080 -> 8081 ----
flip_upstream "$CF" 8080 8081; rc=$?
assert_rc "flip_upstream 8080->8081 returns 0" 0 "$rc"
assert_contains "coordinator upstream now 8081" "$CF" "reverse_proxy 127.0.0.1:8081"
assert_absent  "old coordinator upstream 8080 gone" "$CF" "reverse_proxy 127.0.0.1:8080"
assert_eq "current_upstream_port reads 8081 after flip" "8081" "$(current_upstream_port "$CF")"

# ---- only the coordinator line changed (exactly 1 removed + 1 added) ----
diffout="$(diff "$ORIG" "$CF")"
removed="$(printf '%s\n' "$diffout" | grep -c '^<')"
added="$(printf '%s\n' "$diffout" | grep -c '^>')"
assert_eq "exactly one line removed by flip" "1" "$removed"
assert_eq "exactly one line added by flip" "1" "$added"

# ---- step-ca / MicroMDM / /dl static / internal-listener lines untouched ----
assert_contains "step-ca upstream :9000 untouched" "$CF" "reverse_proxy https://127.0.0.1:9000"
assert_contains "MicroMDM upstream :9002 untouched" "$CF" "reverse_proxy https://127.0.0.1:9002"
assert_contains "/dl/* static handler untouched by flip" "$CF" "handle /dl/* {"
assert_contains "/enroll.mobileconfig static handler untouched by flip" "$CF" "handle /enroll.mobileconfig {"
assert_contains "internal webhook listener :8090 untouched" "$CF" "http://127.0.0.1:8090 {"

# ---- reversible: flip back restores the file byte-for-byte ----
flip_upstream "$CF" 8081 8080; rc=$?
assert_rc "flip_upstream 8081->8080 returns 0" 0 "$rc"
if diff -q "$ORIG" "$CF" >/dev/null; then
  pass "flip is reversible (file identical to original)"
else
  fail "flip is reversible" "$(diff "$ORIG" "$CF")"
fi

# ---- idempotent: flipping when from-port is absent is a no-op (rc 3) ----
cp "$ORIG" "$CF"
flip_upstream "$CF" 8080 8081 >/dev/null; rc=$?   # first: changes
assert_rc "first flip changes (rc 0)" 0 "$rc"
before_second="$(cat "$CF")"
flip_upstream "$CF" 8080 8081 >/dev/null 2>&1; rc=$?   # second: 8080 already gone
assert_rc "second identical flip is a no-op (rc 3)" 3 "$rc"
assert_eq "file unchanged after no-op flip" "$before_second" "$(cat "$CF")"

# ---- error handling ----
flip_upstream "$WORK/does-not-exist" 8080 8081 >/dev/null 2>&1; rc=$?
assert_rc "flip_upstream on missing file returns 2" 2 "$rc"
flip_upstream "$CF" >/dev/null 2>&1; rc=$?
assert_rc "flip_upstream with too few args returns 2" 2 "$rc"
current_upstream_port "$WORK/does-not-exist" >/dev/null 2>&1; rc=$?
assert_rc "current_upstream_port on missing file returns 2" 2 "$rc"

# ---- a Caddyfile with no coordinator upstream -> rc 3 ----
printf 'example.com {\n\trespond "hi"\n}\n' > "$WORK/no-upstream"
current_upstream_port "$WORK/no-upstream" >/dev/null 2>&1; rc=$?
assert_rc "current_upstream_port with no upstream returns 3" 3 "$rc"

# ---- color/port helpers ----
assert_eq "port_for_color blue" "8080" "$(port_for_color blue)"
assert_eq "port_for_color green" "8081" "$(port_for_color green)"
assert_eq "color_for_port 8080" "blue" "$(color_for_port 8080)"
assert_eq "color_for_port 8081" "green" "$(color_for_port 8081)"
assert_eq "other_color blue" "green" "$(other_color blue)"
assert_eq "other_color green" "blue" "$(other_color green)"

echo
echo "# deploy_test: load_admin_env (PARSE the admin key — never source the env file)"

# load_admin_env reads ONLY EIGENINFERENCE_ADMIN_KEY from a docker --env-file
# (KEY=VALUE) file. It must NEVER source/eval it (the file holds secrets like the
# 12-word MNEMONIC and URLs with shell metacharacters that would run AS ROOT).
SECENV="$WORK/secrets.env"
# shellcheck disable=SC2034  # read by load_admin_env() in the sourced deploy.sh
DINF_ENV_FILE="$SECENV"

printf 'EIGENINFERENCE_ADMIN_KEY=plainkey123\nOTHER=x\n' > "$SECENV"
EIGENINFERENCE_ADMIN_KEY=""; load_admin_env
assert_eq "load_admin_env reads a plain key" "plainkey123" "${EIGENINFERENCE_ADMIN_KEY:-}"

printf 'EIGENINFERENCE_ADMIN_KEY=a=b=c\n' > "$SECENV"
EIGENINFERENCE_ADMIN_KEY=""; load_admin_env
assert_eq "load_admin_env keeps '=' chars in the value (cut -f2-)" "a=b=c" "${EIGENINFERENCE_ADMIN_KEY:-}"

printf 'EIGENINFERENCE_ADMIN_KEY="quotedkey"\n' > "$SECENV"
EIGENINFERENCE_ADMIN_KEY=""; load_admin_env
assert_eq "load_admin_env strips surrounding double quotes" "quotedkey" "${EIGENINFERENCE_ADMIN_KEY:-}"

printf "EIGENINFERENCE_ADMIN_KEY='quotedkey2'\n" > "$SECENV"
EIGENINFERENCE_ADMIN_KEY=""; load_admin_env
assert_eq "load_admin_env strips surrounding single quotes" "quotedkey2" "${EIGENINFERENCE_ADMIN_KEY:-}"

# SECURITY REGRESSION: hostile values (command substitution) must NOT execute.
# Sourcing the file (the bug this fixes) would run touch $CANARY; parsing must not.
CANARY="$WORK/CANARY_EXECUTED"
rm -f "$CANARY"
cat > "$SECENV" <<EOF2
MNEMONIC=word1 word2 \$(touch $CANARY) more
EVIL=\`touch $CANARY\`
EIGENINFERENCE_ADMIN_KEY=safekey
EOF2
EIGENINFERENCE_ADMIN_KEY=""; load_admin_env
assert_eq "load_admin_env reads the key past hostile lines" "safekey" "${EIGENINFERENCE_ADMIN_KEY:-}"
if [ ! -e "$CANARY" ]; then
  pass "load_admin_env does NOT execute env-file values (no source/eval)"
else
  fail "SECURITY: env-file value was executed" "canary $CANARY exists"
fi

printf 'OTHER=x\n' > "$SECENV"
EIGENINFERENCE_ADMIN_KEY=""; load_admin_env
assert_eq "load_admin_env yields empty key when absent" "" "${EIGENINFERENCE_ADMIN_KEY:-}"

echo
echo "# deploy_test: provider wait timeout"

# wait_for_providers must return nonzero on timeout so forward deploy can abort
# before draining/stopping the old color. Use a zero-second timeout so no network
# or curl mock is required.
# shellcheck disable=SC2034  # read by wait_for_providers in sourced deploy.sh
PROVIDERS_TIMEOUT=0
wait_for_providers blue 8080 >/dev/null 2>&1; rc=$?
assert_rc "wait_for_providers returns nonzero on timeout" 1 "$rc"
# shellcheck disable=SC2034  # read by wait_for_providers in sourced deploy.sh
DRY_RUN=1
wait_for_providers blue 8080 >/dev/null 2>&1; rc=$?
assert_rc "wait_for_providers dry-run returns 0" 0 "$rc"

echo
echo "# deploy_test: per-color image-pin rollback (pin_image / restore_image_pin / accept_image_pin)"

# shellcheck disable=SC2034  # DRY_RUN read by the dry-run guards in sourced deploy.sh
DRY_RUN=0
PIN_TMPL="$WORK/deploy-%s.env"
PINBLUE="$WORK/deploy-blue.env"
PINGREEN="$WORK/deploy-green.env"
# shellcheck disable=SC2034  # read by deploy_env_for_color/pin_image in sourced deploy.sh
DINF_DEPLOY_ENV_TMPL="$PIN_TMPL"
# DINF_DEPLOY_ENV_BAK / DINF_DEPLOY_ENV_EXISTED / DINF_DEPLOY_ENV_PINNED are set by
# pin_image itself, so the tests below intentionally do NOT pre-seed them.

assert_eq "deploy_env_for_color blue" "$PINBLUE" "$(deploy_env_for_color blue)"
assert_eq "deploy_env_for_color green" "$PINGREEN" "$(deploy_env_for_color green)"
deploy_env_for_color red >/dev/null 2>&1; rc=$?
assert_rc "deploy_env_for_color rejects unknown colors" 2 "$rc"

# (a) pin when the color file did NOT exist -> restore removes only that file.
rm -f "$PINBLUE" "$PINGREEN"
pin_image blue "repo/coord:abc" >/dev/null 2>&1; rc=$?
assert_rc "pin_image blue returns 0" 0 "$rc"
assert_contains "pin_image writes DINF_IMAGE to blue" "$PINBLUE" "DINF_IMAGE=repo/coord:abc"
if [ ! -f "$PINGREEN" ]; then pass "pin_image blue does not create green pin file"; else fail "pin_image blue should not create green pin file"; fi
restore_image_pin >/dev/null 2>&1
if [ ! -f "$PINBLUE" ]; then pass "restore_image_pin removes a blue pin file created this run"; else fail "restore_image_pin should remove a newly-created blue pin file"; fi

# (b) pin OVER an existing file -> accept keeps it (restore becomes a no-op).
printf 'OTHER=1\n' > "$PINGREEN"
pin_image green "repo/coord:def" >/dev/null 2>&1; rc=$?
assert_rc "pin_image green returns 0" 0 "$rc"
assert_contains "pin_image preserves other keys in green" "$PINGREEN" "OTHER=1"
assert_contains "pin_image sets the new image in green" "$PINGREEN" "DINF_IMAGE=repo/coord:def"
accept_image_pin
restore_image_pin >/dev/null 2>&1
assert_contains "accept_image_pin keeps the green pin (restore is a no-op)" "$PINGREEN" "DINF_IMAGE=repo/coord:def"

# (c) pin OVER an existing pinned file -> restore brings back the original image
# in the exact file pin_image touched, even if the template changes before restore.
printf 'DINF_IMAGE=old/img:1\nOTHER=2\n' > "$PINBLUE"
pin_image blue "new/img:2" >/dev/null 2>&1; rc=$?
assert_rc "pin_image blue over existing pin returns 0" 0 "$rc"
assert_contains "pin_image replaces the old blue image line" "$PINBLUE" "DINF_IMAGE=new/img:2"
assert_absent  "pin_image drops the prior blue image line" "$PINBLUE" "DINF_IMAGE=old/img:1"
# shellcheck disable=SC2034  # restore_image_pin must use DINF_DEPLOY_ENV_PINNED, not this new template
DINF_DEPLOY_ENV_TMPL="$WORK/other-%s.env"
restore_image_pin >/dev/null 2>&1
assert_contains "restore_image_pin restores the prior blue image pin" "$PINBLUE" "DINF_IMAGE=old/img:1"
assert_absent  "restore_image_pin drops the unaccepted blue image pin" "$PINBLUE" "DINF_IMAGE=new/img:2"
if [ ! -e "$WORK/other-blue.env" ]; then pass "restore_image_pin uses the pinned file, not the current template"; else fail "restore_image_pin wrote to the current template instead of pinned file"; fi

# (d) pin_image fails before restart if the per-color env path cannot be written.
BAD_PARENT="$WORK/not-a-dir"
printf 'x\n' > "$BAD_PARENT"
# shellcheck disable=SC2034  # read by deploy_env_for_color/pin_image in sourced deploy.sh
DINF_DEPLOY_ENV_TMPL="$BAD_PARENT/deploy-%s.env"
pin_image blue "bad/img:1" >/dev/null 2>&1; rc=$?
assert_rc "pin_image fails when deploy env directory cannot be created" 1 "$rc"

echo
echo "# deploy_test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
