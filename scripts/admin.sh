#!/bin/bash
set -euo pipefail

# DGInf Admin CLI
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
# The admin token is stored at ~/.dginf/admin_token and reused until it expires.

COORDINATOR_URL="${DGINF_COORDINATOR_URL:-https://inference-test.openinnovation.dev}"
TOKEN_FILE="$HOME/.dginf/admin_token"

# ─── Auth helpers ───────────────────────────────────────────

get_token() {
    # Check for admin key (dev/pre-prod).
    if [ -n "${DGINF_ADMIN_KEY:-}" ]; then
        echo "$DGINF_ADMIN_KEY"
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
    echo "DGInf Admin Login"
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
    authed_curl "$COORDINATOR_URL/v1/admin/models" | python3 -m json.tool
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
        echo "  raw <METHOD> <path> [body]     Raw API call with auth"
        echo ""
        echo "Environment:"
        echo "  DGINF_COORDINATOR_URL   Coordinator URL (default: https://inference-test.openinnovation.dev)"
        echo "  DGINF_ADMIN_KEY         Admin key (pre-prod shortcut, skips Privy login)"
        ;;
    *)
        echo "Unknown command: $1. Run '$0 help' for usage."
        exit 1
        ;;
esac
