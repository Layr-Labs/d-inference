#!/bin/bash
set -euo pipefail

# EigenInference Admin CLI
#
# Authenticate with Privy and manage releases, models, and pricing.
#
# Usage:
#   ./scripts/admin.sh login                    # Authenticate (email OTP)
#   ./scripts/admin.sh releases list            # List all releases
#   ./scripts/admin.sh releases deactivate 0.2.0  # Deactivate a version
#   ./scripts/admin.sh models list              # List model catalog
#   ./scripts/admin.sh raw GET /v1/admin/releases  # Raw API call
#
# The admin token is stored at ~/.darkbloom/admin_token and reused until it expires.

COORDINATOR_URL="${EIGENINFERENCE_COORDINATOR_URL:-https://api.darkbloom.dev}"
TOKEN_FILE="$HOME/.darkbloom/admin_token"

# ─── Auth helpers ───────────────────────────────────────────

get_token() {
    # Check for admin key (dev/pre-prod).
    if [ -n "${EIGENINFERENCE_ADMIN_KEY:-}" ]; then
        echo "$EIGENINFERENCE_ADMIN_KEY"
        return
    fi

    # Check for stored Privy token.
    if [ -f "$TOKEN_FILE" ]; then
        cat "$TOKEN_FILE"
        return
    fi

    echo ""
}

authed_curl() {
    local token
    token=$(get_token)
    if [ -z "$token" ]; then
        echo "Not authenticated. Run: $0 login" >&2
        exit 1
    fi
    curl -fsSL -H "Authorization: Bearer $token" "$@"
}

# ─── Commands ───────────────────────────────────────────────

cmd_login() {
    echo "EigenInference Admin Login"
    echo ""
    read -p "Email: " EMAIL

    echo "Sending OTP to $EMAIL..."
    INIT_RESP=$(curl -fsSL -X POST "$COORDINATOR_URL/v1/admin/auth/init" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$EMAIL\"}" 2>&1) || {
        echo "Failed to send OTP: $INIT_RESP"
        exit 1
    }

    echo "Check your email for the verification code."
    read -p "OTP Code: " CODE

    echo "Verifying..."
    VERIFY_RESP=$(curl -fsSL -X POST "$COORDINATOR_URL/v1/admin/auth/verify" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$EMAIL\", \"code\": \"$CODE\"}")

    TOKEN=$(echo "$VERIFY_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
    if [ -z "$TOKEN" ]; then
        echo "Login failed: $VERIFY_RESP"
        exit 1
    fi

    mkdir -p "$(dirname "$TOKEN_FILE")"
    echo -n "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "Logged in as $EMAIL"
    echo "Token stored at $TOKEN_FILE"
}

cmd_logout() {
    rm -f "$TOKEN_FILE"
    echo "Logged out. Token removed."
}

cmd_releases_list() {
    authed_curl "$COORDINATOR_URL/v1/admin/releases" | python3 -m json.tool
}

cmd_releases_deactivate() {
    local version="${1:?Usage: $0 releases deactivate <version>}"
    local platform="${2:-macos-arm64}"
    authed_curl -X DELETE "$COORDINATOR_URL/v1/admin/releases" \
        -H "Content-Type: application/json" \
        -d "{\"version\": \"$version\", \"platform\": \"$platform\"}"
    echo ""
    echo "Release $version ($platform) deactivated."
}

cmd_releases_latest() {
    local platform="${1:-macos-arm64}"
    curl -fsSL "$COORDINATOR_URL/v1/releases/latest?platform=$platform" | python3 -m json.tool
}

cmd_models_list() {
    # Public, registry-backed catalog (the legacy /v1/admin/models CRUD was removed).
    curl -fsSL "$COORDINATOR_URL/v1/models/catalog" | python3 -m json.tool
}

cmd_hardware_policy_get() {
    authed_curl "$COORDINATOR_URL/v1/admin/hardware-admission/policy" | python3 -m json.tool
}

cmd_hardware_policy_machines() {
    authed_curl "$COORDINATOR_URL/v1/admin/hardware-admission/machines" | python3 -m json.tool
}

cmd_hardware_policy_revoke() {
    local serial="${1:?Usage: $0 hardware-policy revoke <serial> <reason>}"
    local reason="${2:?reason is required}"
    local body
    body="$(python3 - "$reason" <<'PY'
import json
import sys
print(json.dumps({"reason": sys.argv[1]}))
PY
)"
    authed_curl -X DELETE "$COORDINATOR_URL/v1/admin/hardware-admission/machines/$serial" \
        -H "Content-Type: application/json" -d "$body" | python3 -m json.tool
}

cmd_hardware_policy_restore() {
    local serial="${1:?Usage: $0 hardware-policy restore <serial> <reason>}"
    local reason="${2:?reason is required}"
    local body
    body="$(python3 - "$serial" "$reason" <<'PY'
import json
import sys
print(json.dumps({"serial_number": sys.argv[1], "reason": sys.argv[2]}))
PY
)"
    authed_curl -X POST "$COORDINATOR_URL/v1/admin/hardware-admission/machines/restore" \
        -H "Content-Type: application/json" -d "$body" | python3 -m json.tool
}

cmd_hardware_policy_set() {
    local mode="${1:?Usage: $0 hardware-policy set <disabled|shadow|enforce> <memory-gb> <bandwidth-gbs> <fp16-millitflops> <expected-version> [reason]}"
    local memory_gb="${2:?memory-gb is required}"
    local bandwidth_gbs="${3:?bandwidth-gbs is required}"
    local fp16_millitflops="${4:?fp16-millitflops is required}"
    local expected_version="${5:?expected-version is required}"
    local reason="${6:-operator policy update}"
    local body
    body="$(python3 - "$mode" "$memory_gb" "$bandwidth_gbs" "$fp16_millitflops" "$expected_version" "$reason" <<'PY'
import json
import sys

print(json.dumps({
    "mode": sys.argv[1],
    "min_memory_gb": int(sys.argv[2]),
    "min_memory_bandwidth_gbs": int(sys.argv[3]),
    "min_fp16_millitflops": int(sys.argv[4]),
    "expected_current_version": int(sys.argv[5]),
    "reason": sys.argv[6],
}))
PY
)"
    authed_curl -X PUT "$COORDINATOR_URL/v1/admin/hardware-admission/policy" \
        -H "Content-Type: application/json" \
        -d "$body" | python3 -m json.tool
}

cmd_raw() {
    local method="${1:?Usage: $0 raw <METHOD> <path> [body]}"
    local path="${2:?Usage: $0 raw <METHOD> <path> [body]}"
    local body="${3:-}"

    if [ -n "$body" ]; then
        authed_curl -X "$method" "$COORDINATOR_URL$path" \
            -H "Content-Type: application/json" \
            -d "$body"
    else
        authed_curl -X "$method" "$COORDINATOR_URL$path"
    fi
    echo ""
}

# ─── Dispatch ───────────────────────────────────────────────

case "${1:-help}" in
    login)
        cmd_login
        ;;
    logout)
        cmd_logout
        ;;
    releases)
        case "${2:-list}" in
            list) cmd_releases_list ;;
            deactivate) cmd_releases_deactivate "${3:-}" "${4:-}" ;;
            latest) cmd_releases_latest "${3:-}" ;;
            *) echo "Usage: $0 releases [list|deactivate|latest]" ;;
        esac
        ;;
    models)
        case "${2:-list}" in
            list) cmd_models_list ;;
            *) echo "Usage: $0 models [list]" ;;
        esac
        ;;
    hardware-policy)
        case "${2:-get}" in
            get) cmd_hardware_policy_get ;;
            machines) cmd_hardware_policy_machines ;;
            revoke) cmd_hardware_policy_revoke "${3:-}" "${4:-}" ;;
            restore) cmd_hardware_policy_restore "${3:-}" "${4:-}" ;;
            set) cmd_hardware_policy_set "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" ;;
            *) echo "Usage: $0 hardware-policy [get|machines|set|revoke|restore]" ;;
        esac
        ;;
    raw)
        cmd_raw "${2:-}" "${3:-}" "${4:-}"
        ;;
    help|--help|-h)
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  login                          Authenticate with Privy (email OTP)"
        echo "  logout                         Remove stored token"
        echo "  releases list                  List all releases"
        echo "  releases latest [platform]     Show latest active release"
        echo "  releases deactivate <version>  Deactivate a release"
        echo "  models list                    List model catalog"
        echo "  hardware-policy get            Show active provider hardware policy"
        echo "  hardware-policy machines       List admitted machines and recent decisions"
        echo "  hardware-policy revoke <serial> <reason>"
        echo "  hardware-policy restore <serial> <reason>"
        echo "  hardware-policy set <mode> <memory-gb> <bandwidth-gbs> <fp16-millitflops> <expected-version> [reason]"
        echo "  raw <METHOD> <path> [body]     Raw API call with auth"
        echo ""
        echo "Environment:"
        echo "  EIGENINFERENCE_COORDINATOR_URL   Coordinator URL (default: https://api.darkbloom.dev)"
        echo "  EIGENINFERENCE_ADMIN_KEY         Admin key (pre-prod shortcut, skips Privy login)"
        ;;
    *)
        echo "Unknown command: $1. Run '$0 help' for usage."
        exit 1
        ;;
esac
