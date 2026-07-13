#!/bin/sh
# Validate deployment PKCS#12 identities without printing key material.
set -eu
LC_ALL=C
export LC_ALL

fail() {
    echo "PKCS#12 validation failed: $*" >&2
    exit 1
}

role=${2:-}
case "$role" in
    mdm|profile) ;;
    *) fail "identity role must be mdm or profile" ;;
esac

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT HUP INT TERM

decode_base64() {
    encoded=$1
    output=$2
    [ -n "$encoded" ] || fail "$role bundle is empty"
    printf '%s' "$encoded" | tr '_-' '/+' >"$work/bundle.b64"
    encoded_length=$(wc -c <"$work/bundle.b64" | tr -d ' ')
    case $((encoded_length % 4)) in
        0) ;;
        2) printf '==' >>"$work/bundle.b64" ;;
        3) printf '=' >>"$work/bundle.b64" ;;
        *) fail "$role bundle has invalid base64 length" ;;
    esac
    base64 -d <"$work/bundle.b64" >"$output" 2>/dev/null ||
        fail "$role bundle is not valid base64"
    [ -s "$output" ] || fail "$role bundle decoded empty"
}

load_bundle() {
    case "$role" in
        mdm)
            decode_base64 "${MDM_PUSH_P12_B64:-}" "$work/bundle.p12"
            password=${MDM_PUSH_P12_PASSWORD:-eigeninference}
            ;;
        profile)
            if [ -n "${PROFILE_SIGNING_P12_B64:-}" ]; then
                decode_base64 "$PROFILE_SIGNING_P12_B64" "$work/bundle.p12"
            elif [ -n "${PROFILE_SIGNING_P12_PATH:-}" ]; then
                [ -r "$PROFILE_SIGNING_P12_PATH" ] ||
                    fail "profile bundle path is unreadable"
                cp "$PROFILE_SIGNING_P12_PATH" "$work/bundle.p12"
            else
                fail "profile bundle is not configured"
            fi
            password=${PROFILE_SIGNING_P12_PASSWORD:-}
            ;;
    esac
}

extract_bundle() {
    if ! openssl pkcs12 -in "$work/bundle.p12" -clcerts -nokeys \
        -passin "pass:$password" -out "$work/extracted.crt" 2>/dev/null; then
        rm -f "$work/extracted.crt"
        openssl pkcs12 -legacy -in "$work/bundle.p12" -clcerts -nokeys \
            -passin "pass:$password" -out "$work/extracted.crt" 2>/dev/null ||
            fail "$role bundle or configured password is invalid"
    fi
    if ! openssl pkcs12 -in "$work/bundle.p12" -nocerts -nodes \
        -passin "pass:$password" -out "$work/extracted.key" 2>/dev/null; then
        rm -f "$work/extracted.key"
        openssl pkcs12 -legacy -in "$work/bundle.p12" -nocerts -nodes \
            -passin "pass:$password" -out "$work/extracted.key" 2>/dev/null ||
            fail "$role bundle or configured password is invalid"
    fi
    cert_count=$(awk '/-----BEGIN CERTIFICATE-----/ { count++ } END { print count + 0 }' \
        "$work/extracted.crt")
    key_count=$(awk '/-----BEGIN .*PRIVATE KEY-----/ { count++ } END { print count + 0 }' \
        "$work/extracted.key")
    [ "$cert_count" -eq 1 ] ||
        fail "$role bundle must contain exactly one leaf certificate"
    [ "$key_count" -eq 1 ] ||
        fail "$role bundle must contain exactly one private key"
    openssl x509 -in "$work/extracted.crt" -out "$work/cert.pem" 2>/dev/null ||
        fail "$role leaf certificate is invalid"
    openssl pkey -in "$work/extracted.key" -out "$work/key.pem" 2>/dev/null ||
        fail "$role private key is invalid"
}

validate_identity() {
    cert=$1
    key=$2
    if [ ! -r "$cert" ] || [ ! -r "$key" ]; then
        fail "$role certificate and private key are required"
    fi

    # The leaf is normally Apple- or Developer-ID-issued, not self-signed.
    # Trusting it as its own CA rejects every valid production identity.
    # Deployment validation needs temporal validity, leaf/key matching, and
    # the role-specific usages below; issuer-chain trust remains macOS/Apple's
    # responsibility at enrollment or APNs authentication time.
    openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 ||
        fail "$role certificate is expired or malformed"
    not_before=$(openssl x509 -in "$cert" -noout -startdate -dateopt iso_8601 2>/dev/null |
        sed 's/^notBefore=//; s/ /T/') ||
        fail "$role certificate start date cannot be inspected"
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [ -n "$not_before" ] || fail "$role certificate start date is empty"
    if ! awk -v start="$not_before" -v current="$now" \
        'BEGIN { exit !(("x" start) <= ("x" current)) }'; then
        fail "$role certificate is not yet valid"
    fi

    cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}') ||
        fail "$role certificate public key is invalid"
    key_public=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}') ||
        fail "$role private key is invalid"
    [ "$cert_public" = "$key_public" ] ||
        fail "$role certificate and private key do not match"

    certificate_text=$(openssl x509 -in "$cert" -noout -text 2>/dev/null) ||
        fail "$role certificate cannot be inspected"
    printf '%s\n' "$certificate_text" |
        awk '
            /X509v3 Basic Constraints:/ {
                getline
                if ($0 ~ /CA:FALSE/) found = 1
            }
            END { exit !found }
        ' || fail "$role certificate must be a non-CA leaf"
    printf '%s\n' "$certificate_text" |
        awk '
            /X509v3 Key Usage:/ {
                getline
                if ($0 ~ /Digital Signature/) found = 1
            }
            END { exit !found }
        ' || fail "$role certificate does not permit digital signatures"

    case "$role" in
        mdm)
            expected_usage='TLS Web Client Authentication'
            ;;
        profile)
            expected_usage='Code Signing'
            ;;
    esac
    printf '%s\n' "$certificate_text" |
        awk -v expected="$expected_usage" '
            /X509v3 Extended Key Usage:/ {
                getline
                if (index($0, expected) || index($0, "Any Extended Key Usage")) found = 1
            }
            END { exit !found }
        ' || fail "$role certificate has the wrong extended key usage"
}

case "${1:-}" in
    bundle)
        load_bundle
        extract_bundle
        validate_identity "$work/cert.pem" "$work/key.pem"
        ;;
    hash)
        load_bundle
        sha256sum "$work/bundle.p12" | awk '{print $1}'
        ;;
    installed)
        [ "$role" = mdm ] || fail "only installed MDM identities are supported"
        [ "$#" -eq 4 ] || fail "usage: coordinator-p12-check installed mdm CERT KEY"
        validate_identity "$3" "$4"
        ;;
    *)
        fail "usage: coordinator-p12-check {bundle|hash} {mdm|profile}"
        ;;
esac
