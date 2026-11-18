#!/usr/bin/env bash
# Import the Developer ID certificate into a new temporary keychain for one
# signing job. Every workflow that signs calls this script, so they all follow
# the same rules:
#   - the keychain password is random and never leaves this script: later
#     steps sign through the unlocked keychain and never need it;
#   - the private key is imported non-extractable (-x) and only codesign may
#     use it;
#   - the decoded certificate exists only under RUNNER_TEMP, readable only by
#     the runner user, and is removed before the script returns, also on
#     failure.
# scripts/remove-signing-keychain.sh deletes the keychain again.
#
# usage: P12_BASE64=... P12_PASSWORD=... import-signing-certificate.sh KEYCHAIN_PATH
set -euo pipefail
umask 077

[[ $# == 1 && -n "$1" ]] || { echo 'usage: import-signing-certificate.sh KEYCHAIN_PATH' >&2; exit 2; }
keychain=$1
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
if [[ -z "${P12_BASE64:-}" || -z "${P12_PASSWORD:-}" ]]; then
  echo '::error::The signing certificate and its password are not configured for this job' >&2
  exit 1
fi
if [[ -e "$keychain" ]]; then
  echo "::error::Signing keychain already exists: $keychain" >&2
  exit 1
fi

certificate=$(mktemp "$RUNNER_TEMP/signing-certificate.XXXXXX")
trap 'rm -f "$certificate"' EXIT
printf '%s' "$P12_BASE64" | base64 --decode > "$certificate"

keychain_password=$(openssl rand -hex 24)
security create-keychain -p "$keychain_password" "$keychain"
# Signing takes minutes; a keychain that outlives its job locks itself.
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
# First in the user search list, so codesign resolves the identity and its chain.
keychains=("$keychain")
while read -r listed; do
  listed="${listed#\"}"
  keychains+=("${listed%\"}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${keychains[@]}"
security import "$certificate" -k "$keychain" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -f pkcs12 -x
security set-key-partition-list -S apple-tool:,apple: \
  -s -k "$keychain_password" "$keychain" >/dev/null
identities=$(security find-identity -v -p codesigning "$keychain")
printf '%s\n' "$identities"
# find-identity exits 0 with "0 valid identities found": refuse a p12 that
# holds no valid signing identity, or not the one this job signs with.
if ! grep -Eq '^ +[1-9][0-9]* valid identities found' <<<"$identities"; then
  echo '::error::The signing certificate holds no valid code-signing identity' >&2
  exit 1
fi
if [[ -n "${DEVELOPER_ID:-}" ]] && ! grep -Fq "\"$DEVELOPER_ID\"" <<<"$identities"; then
  echo '::error::The signing certificate is not the expected Developer ID identity' >&2
  exit 1
fi
