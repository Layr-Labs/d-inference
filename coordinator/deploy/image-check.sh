#!/bin/sh
set -eu

fail() {
    echo "coordinator image check failed: $*" >&2
    exit 1
}

P12_CHECK=${COORDINATOR_P12_CHECK:-/usr/local/bin/coordinator-p12-check}

validate_layout() {
    for binary in \
        coordinator-go \
        coordinator-rs \
        coordinator-migrate \
        coordinator-healthcheck \
        coordinator-p12-check \
        micromdm-api-check \
        mdm-cert-rotate \
        start.sh; do
        [ -x "/usr/local/bin/$binary" ] || fail "missing executable $binary"
    done
    for command_name in base64 curl install jq mdmctl openssl printenv sha256sum wget; do
        command -v "$command_name" >/dev/null 2>&1 ||
            fail "$command_name is unavailable"
    done
    [ -L /usr/local/bin/coordinator ] || fail "compatibility coordinator is not a symlink"
    [ "$(readlink /usr/local/bin/coordinator)" = "coordinator-go" ] ||
        fail "compatibility coordinator must target coordinator-go"

    linkage=$(ldd /usr/local/bin/coordinator-rs 2>&1 || true)
    if printf '%s\n' "$linkage" | grep -q 'not found'; then
        fail "Rust coordinator has unresolved runtime libraries"
    fi
}

check_version() {
    binary=$1
    expected=$2
    output=$("/usr/local/bin/$binary" version)
    printf '%s\n' "$output" |
        jq -e --arg expected "$expected" \
            '.binary == $expected and
             (.version | type == "string") and
             (.build_commit | type == "string") and
             (.build_date | type == "string")' >/dev/null ||
        fail "$expected version output is invalid"
}

validate_selector() {
    case "${EIGENINFERENCE_COORDINATOR_BINARY:-go}" in
        go)
            SELECTED=/usr/local/bin/coordinator-go
            EXPECTED_BINARY=go
            ;;
        rust)
            SELECTED=/usr/local/bin/coordinator-rs
            EXPECTED_BINARY=rust
            ;;
        *)
            fail "EIGENINFERENCE_COORDINATOR_BINARY must be exactly go or rust"
            ;;
    esac
}

validate_state_mount() {
    persist=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
    [ "$persist" = /mnt/disks/userdata ] ||
        fail "USER_PERSISTENT_DATA_PATH must be /mnt/disks/userdata"
    [ -d "$persist" ] || fail "persistent state directory is missing"
    [ -w "$persist" ] || fail "persistent state directory is not writable"
    awk -v path="$persist" '$5 == path { found = 1 } END { exit !found }' /proc/self/mountinfo ||
        fail "$persist is not a dedicated container mount"
}

validate_p12_identities() {
    case "${MDM_PUSH_P12_VERSION:-}" in
        ''|*[!A-Za-z0-9._:/-]*)
            fail "MDM push Secret Manager version is invalid"
            ;;
    esac
    "$P12_CHECK" bundle mdm ||
        fail "MDM push identity is invalid"
    if [ -n "${PROFILE_SIGNING_P12_B64:-}" ] ||
        [ -n "${PROFILE_SIGNING_P12_PATH:-}" ]; then
        "$P12_CHECK" bundle profile ||
            fail "configuration-profile signing identity is invalid"
    fi
}

mdm_rotation_changed() {
    persist=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
    state_file=$persist/micromdm/.push_imported
    desired_hash=$("$P12_CHECK" hash mdm) ||
        fail "cannot hash MDM push identity"
    desired_version=${MDM_PUSH_P12_VERSION:-}
    current_hash=
    current_version=
    if [ -r "$state_file" ]; then
        current_hash=$(awk -F= '$1 == "hash" { print substr($0, 6); exit }' "$state_file")
        current_version=$(awk -F= '$1 == "version" { print substr($0, 9); exit }' "$state_file")
    fi
    [ "$desired_hash" != "$current_hash" ] ||
        [ "$desired_version" != "$current_version" ]
}

check_current_micromdm_api() {
    if ! /usr/local/bin/micromdm-api-check; then
        fail "current MicroMDM API preflight failed for certificate rotation"
    fi
}

validate_rotation_preflight() {
    persist=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
    state_file=$persist/micromdm/.push_imported
    cert_file=$persist/micromdm/push.crt
    key_file=$persist/micromdm/push.key
    if mdm_rotation_changed &&
        { [ -e "$state_file" ] || [ -e "$cert_file" ] || [ -e "$key_file" ]; }; then
        check_current_micromdm_api
    fi
}

validate_rotation_applied() {
    persist=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
    state_file=$persist/micromdm/.push_imported
    cert_file=$persist/micromdm/push.crt
    key_file=$persist/micromdm/push.key
    desired_hash=$("$P12_CHECK" hash mdm) ||
        fail "cannot hash MDM push identity"
    desired_version=${MDM_PUSH_P12_VERSION:-}
    if [ ! -r "$state_file" ] || [ ! -r "$cert_file" ] ||
        [ ! -r "$key_file" ]; then
        fail "MDM push rotation has no committed identity"
    fi
    current_hash=$(awk -F= '$1 == "hash" { print substr($0, 6); exit }' "$state_file")
    current_version=$(awk -F= '$1 == "version" { print substr($0, 9); exit }' "$state_file")
    if [ "$desired_hash" != "$current_hash" ] ||
        [ "$desired_version" != "$current_version" ]; then
        fail "MDM push rotation did not commit the requested version and hash"
    fi
    "$P12_CHECK" installed mdm "$cert_file" "$key_file" ||
        fail "committed MDM push identity is invalid"
}

validate_required_secrets() {
    for variable in \
        EIGENINFERENCE_ADMIN_KEY \
        EIGENINFERENCE_RELEASE_KEY \
        EIGENINFERENCE_PRIVY_APP_ID \
        EIGENINFERENCE_PRIVY_APP_SECRET \
        EIGENINFERENCE_DATABASE_URL \
        MNEMONIC \
        MICROMDM_API_KEY \
        EIGENINFERENCE_MDM_API_KEY \
        EIGENINFERENCE_MDM_WEBHOOK_SECRET \
        MDM_PUSH_P12_B64 \
        MDM_PUSH_P12_VERSION \
        EIGENINFERENCE_R2_CDN_URL \
        EIGENINFERENCE_STRIPE_SECRET_KEY \
        EIGENINFERENCE_STRIPE_WEBHOOK_SECRET \
        EIGENINFERENCE_STRIPE_SUCCESS_URL \
        EIGENINFERENCE_STRIPE_CANCEL_URL \
        EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET \
        EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL \
        EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL; do
        [ -n "$(printenv "$variable")" ] ||
            fail "required runtime secret $variable is empty"
    done
    verification_key=${EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE:-}
    if [ -z "$verification_key" ] || [ ! -r "$verification_key" ]; then
        fail "Privy verification key file is unavailable"
    fi
    if [ "$EXPECTED_BINARY" = rust ]; then
        for variable in \
            EIGENINFERENCE_RUST_PROCESS_X25519_KEY_ID \
            EIGENINFERENCE_RUST_PROCESS_X25519_PRIVATE_KEY \
            EIGENINFERENCE_RUST_PROCESS_X25519_PUBLIC_KEY; do
            [ -n "$(printenv "$variable")" ] ||
                fail "required Rust secret $variable is empty"
        done
    fi
}

validate_layout
case "${1:-}" in
    smoke)
        check_version coordinator-go go
        check_version coordinator-rs rust
        ;;
    config)
        validate_selector
        validate_state_mount
        validate_required_secrets
        validate_p12_identities
        validate_rotation_preflight
        "$SELECTED" check-config |
            jq -e --arg binary "$EXPECTED_BINARY" '
                .binary == $binary and
                .configuration_valid == true and
                .database_configured == true and
                .ownership_configured == true and
                ($binary != "rust" or .full_surface_configured == true)
            ' >/dev/null ||
            fail "selected coordinator rejected configuration"
        ;;
    rotation)
        validate_selector
        validate_state_mount
        validate_required_secrets
        validate_p12_identities
        validate_rotation_applied
        ;;
    *)
        echo "usage: coordinator-image-check {smoke|config|rotation}" >&2
        exit 64
        ;;
esac
