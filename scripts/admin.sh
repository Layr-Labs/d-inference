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
#   ./scripts/admin.sh enterprise list          # List Enterprise accounts
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
    authed_curl "$COORDINATOR_URL/v1/admin/models" | python3 -m json.tool
}

cmd_enterprise_list() {
    authed_curl "$COORDINATOR_URL/v1/admin/enterprise/accounts" | python3 -m json.tool
}

cmd_enterprise_set() {
    local account_id=""
    local email=""
    local cadence=""
    local terms_days=""
    local credit_limit_usd=""
    local status=""
    local stripe_customer_id=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --account-id) account_id="${2:-}"; shift 2 ;;
            --email) email="${2:-}"; shift 2 ;;
            --cadence) cadence="${2:-}"; shift 2 ;;
            --terms-days) terms_days="${2:-}"; shift 2 ;;
            --credit-limit-usd) credit_limit_usd="${2:-}"; shift 2 ;;
            --status) status="${2:-}"; shift 2 ;;
            --stripe-customer-id) stripe_customer_id="${2:-}"; shift 2 ;;
            *) echo "Unknown enterprise set option: $1" >&2; exit 1 ;;
        esac
    done
    if [ -z "$account_id" ] || [ -z "$email" ] || [ -z "$credit_limit_usd" ]; then
        echo "Usage: $0 enterprise set --account-id <acct> --email <billing@email> --credit-limit-usd <usd> [--cadence weekly|biweekly|monthly] [--terms-days 15] [--status active|disabled] [--stripe-customer-id cus_...]" >&2
        exit 1
    fi

    local credit_micro
    credit_micro=$(python3 - "$credit_limit_usd" <<'PY'
import decimal, sys
v = decimal.Decimal(sys.argv[1])
print(int(v * decimal.Decimal(1000000)))
PY
)
    local body
    body=$(python3 - "$account_id" "$email" "$cadence" "$terms_days" "$credit_micro" "$status" "$stripe_customer_id" <<'PY'
import json, sys
account_id, email, cadence, terms_days, credit_micro, status, stripe_customer_id = sys.argv[1:]
body = {
    "account_id": account_id,
    "billing_email": email,
    "credit_limit_micro_usd": int(credit_micro),
}
if cadence:
    body["cadence"] = cadence
if status:
    body["status"] = status
if terms_days:
    body["terms_days"] = int(terms_days)
if stripe_customer_id:
    body["stripe_customer_id"] = stripe_customer_id
print(json.dumps(body))
PY
)
    authed_curl -X PUT "$COORDINATOR_URL/v1/admin/enterprise/account" \
        -H "Content-Type: application/json" \
        -d "$body" | python3 -m json.tool
}

cmd_enterprise_run_invoices() {
    local account_id="${1:-}"
    local body="{}"
    if [ -n "$account_id" ]; then
        body=$(python3 - "$account_id" <<'PY'
import json, sys
print(json.dumps({"account_id": sys.argv[1]}))
PY
)
    fi
    authed_curl -X POST "$COORDINATOR_URL/v1/admin/enterprise/invoices/run" \
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
    enterprise)
        case "${2:-list}" in
            list) cmd_enterprise_list ;;
            set) shift 2; cmd_enterprise_set "$@" ;;
            run-invoices) cmd_enterprise_run_invoices "${3:-}" ;;
            *) echo "Usage: $0 enterprise [list|set|run-invoices]" ;;
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
        echo "  enterprise list                List Enterprise accounts"
        echo "  enterprise set --account-id <acct> --email <email> --credit-limit-usd <usd> [--cadence monthly] [--terms-days 15]"
        echo "  enterprise run-invoices [acct] Generate due Enterprise invoices"
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
