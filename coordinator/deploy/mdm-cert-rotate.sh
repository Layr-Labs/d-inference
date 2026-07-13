#!/bin/sh
# Rotate MicroMDM's APNs certificate without replacing the last working files
# until the new certificate has been validated and uploaded successfully.
set -eu

MDM_DIR=${MDM_CERT_DIRECTORY:-/data/micromdm}
STATE_FILE=$MDM_DIR/.push_imported
MAX_ATTEMPTS=${MDM_CERT_UPLOAD_ATTEMPTS:-5}
RETRY_SECONDS=${MDM_CERT_UPLOAD_RETRY_SECONDS:-2}
P12_PASSWORD=${MDM_PUSH_P12_PASSWORD:-eigeninference}
P12_CHECK=${COORDINATOR_P12_CHECK:-/usr/local/bin/coordinator-p12-check}

case "$MAX_ATTEMPTS" in
    ''|*[!0-9]*) echo "MDM_CERT_UPLOAD_ATTEMPTS must be a positive integer" >&2; exit 64 ;;
esac
[ "$MAX_ATTEMPTS" -gt 0 ] || {
    echo "MDM_CERT_UPLOAD_ATTEMPTS must be a positive integer" >&2
    exit 64
}
case "$RETRY_SECONDS" in
    ''|*[!0-9]*) echo "MDM_CERT_UPLOAD_RETRY_SECONDS must be a non-negative integer" >&2; exit 64 ;;
esac

[ -n "${MDM_PUSH_P12_B64:-}" ] || exit 0
[ -x "$P12_CHECK" ] || {
    echo "coordinator-p12-check is unavailable" >&2
    exit 1
}
"$P12_CHECK" bundle mdm
VERSION=${MDM_PUSH_P12_VERSION:-unknown}
case "$VERSION" in
    ''|*[!A-Za-z0-9._:/-]*) echo "MDM_PUSH_P12_VERSION has invalid characters" >&2; exit 64 ;;
esac

mkdir -p "$MDM_DIR"
work=$(mktemp -d "$MDM_DIR/.push-rotation.XXXXXX")
chmod 700 "$work"
next_cert=$MDM_DIR/.push.crt.next.$$
next_key=$MDM_DIR/.push.key.next.$$
next_state=$MDM_DIR/.push_imported.next.$$
commit_started=false
commit_finished=false
had_cert=false
had_key=false
had_state=false

restore_previous_files() {
    if [ "$had_cert" = true ]; then
        mv -f "$work/previous.crt" "$MDM_DIR/push.crt"
    else
        rm -f "$MDM_DIR/push.crt"
    fi
    if [ "$had_key" = true ]; then
        mv -f "$work/previous.key" "$MDM_DIR/push.key"
    else
        rm -f "$MDM_DIR/push.key"
    fi
    if [ "$had_state" = true ]; then
        mv -f "$work/previous.state" "$STATE_FILE"
    else
        rm -f "$STATE_FILE"
    fi
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$commit_started" = true ] && [ "$commit_finished" != true ]; then
        restore_previous_files
    fi
    rm -f "$next_cert" "$next_key" "$next_state"
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$MDM_PUSH_P12_B64" | tr '_-' '/+' >"$work/push.b64"
encoded_length=$(wc -c <"$work/push.b64" | tr -d ' ')
case $((encoded_length % 4)) in
    0) ;;
    2) printf '==' >>"$work/push.b64" ;;
    3) printf '=' >>"$work/push.b64" ;;
    *) echo "MDM push PKCS#12 has invalid base64url length" >&2; exit 1 ;;
esac
base64 -d <"$work/push.b64" >"$work/push.p12"
HASH=$(sha256sum "$work/push.p12" | awk '{print $1}')

if [ -f "$STATE_FILE" ] &&
    [ -f "$MDM_DIR/push.crt" ] &&
    [ -f "$MDM_DIR/push.key" ] &&
    [ "$(awk -F= '$1 == "hash" { print substr($0, 6); exit }' "$STATE_FILE")" = "$HASH" ] &&
    [ "$(awk -F= '$1 == "version" { print substr($0, 9); exit }' "$STATE_FILE")" = "$VERSION" ] &&
    "$P12_CHECK" installed mdm "$MDM_DIR/push.crt" "$MDM_DIR/push.key" \
        >/dev/null 2>&1; then
    exit 0
fi

if ! openssl pkcs12 -in "$work/push.p12" -clcerts -nokeys \
    -passin "pass:$P12_PASSWORD" -out "$work/extracted.crt" 2>/dev/null; then
    rm -f "$work/extracted.crt"
    openssl pkcs12 -legacy -in "$work/push.p12" -clcerts -nokeys \
        -passin "pass:$P12_PASSWORD" -out "$work/extracted.crt" 2>/dev/null
fi
openssl x509 -in "$work/extracted.crt" -out "$work/push.crt" 2>/dev/null
if ! openssl pkcs12 -in "$work/push.p12" -nocerts -nodes \
    -passin "pass:$P12_PASSWORD" -out "$work/extracted.key" 2>/dev/null; then
    rm -f "$work/extracted.key"
    openssl pkcs12 -legacy -in "$work/push.p12" -nocerts -nodes \
        -passin "pass:$P12_PASSWORD" -out "$work/extracted.key" 2>/dev/null
fi
openssl pkey -in "$work/extracted.key" -traditional -out "$work/push.key" 2>/dev/null
chmod 600 "$work/push.key"

cert_public=$(openssl x509 -in "$work/push.crt" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null |
    sha256sum | awk '{print $1}')
key_public=$(openssl pkey -in "$work/push.key" -pubout -outform DER 2>/dev/null |
    sha256sum | awk '{print $1}')
[ "$cert_public" = "$key_public" ] || {
    echo "MDM push certificate and private key do not match" >&2
    exit 1
}

attempt=1
while ! mdmctl mdmcert upload \
    -cert "$work/push.crt" \
    -private-key "$work/push.key" >/dev/null 2>&1; do
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "MDM push certificate upload failed after $attempt attempts" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep "$RETRY_SECONDS"
done

install -m 0644 "$work/push.crt" "$next_cert"
install -m 0600 "$work/push.key" "$next_key"
umask 077
printf 'hash=%s\nversion=%s\n' "$HASH" "$VERSION" >"$next_state"
if [ -f "$MDM_DIR/push.crt" ]; then
    cp -p "$MDM_DIR/push.crt" "$work/previous.crt"
    had_cert=true
fi
if [ -f "$MDM_DIR/push.key" ]; then
    cp -p "$MDM_DIR/push.key" "$work/previous.key"
    had_key=true
fi
if [ -f "$STATE_FILE" ]; then
    cp -p "$STATE_FILE" "$work/previous.state"
    had_state=true
fi

commit_started=true
mv -f "$next_cert" "$MDM_DIR/push.crt"
mv -f "$next_key" "$MDM_DIR/push.key"
mv -f "$next_state" "$STATE_FILE"
commit_finished=true
