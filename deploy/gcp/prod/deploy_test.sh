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
# (:9000) and MicroMDM (:9002) https upstreams plus the single coordinator
# upstream (:8080), imported by two public sites and the internal :8090 listener.
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

# ---- step-ca / MicroMDM / internal-listener lines untouched ----
assert_contains "step-ca upstream :9000 untouched" "$CF" "reverse_proxy https://127.0.0.1:9000"
assert_contains "MicroMDM upstream :9002 untouched" "$CF" "reverse_proxy https://127.0.0.1:9002"
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
echo "# deploy_test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
