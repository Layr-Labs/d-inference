#!/bin/sh
# Authenticated, read-only MicroMDM API reachability check for deploy preflight.
set -eu

fail() {
    echo "MicroMDM API preflight failed: $*" >&2
    exit 1
}

api_url=${EIGENINFERENCE_MDM_URL:-https://localhost:9002}
case "$api_url" in
    https://localhost:9002|https://127.0.0.1:9002) ;;
    *) fail "URL must be the local MicroMDM API" ;;
esac
[ -n "${MICROMDM_API_KEY:-}" ] || fail "API key is empty"

curl_command=${COORDINATOR_CURL:-curl}
command -v "$curl_command" >/dev/null 2>&1 || fail "curl is unavailable"

output=$(mktemp)
chmod 600 "$output"
trap 'rm -f "$output"' EXIT HUP INT TERM

# Supplying the Authorization header through curl's stdin config keeps the API
# key out of argv and process listings. Base64 contains no curl-config quoting
# characters.
authorization=$(printf 'micromdm:%s' "$MICROMDM_API_KEY" | base64 | tr -d '\n')
unset MICROMDM_API_KEY
if ! printf 'header = "Authorization: Basic %s"\n' "$authorization" |
    "$curl_command" --config - \
        --fail \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 3 \
        --max-time 5 \
        --header 'Content-Type: application/json' \
        --request POST \
        --data '{"serial_number":"__darkbloom_deploy_preflight__"}' \
        --output "$output" \
        "${api_url}/v1/devices"; then
    unset authorization
    fail "authenticated request failed"
fi
unset authorization

jq -e '.devices | type == "array"' "$output" >/dev/null ||
    fail "API returned an invalid response"
