#!/usr/bin/env bash
# Delete the temporary signing keychain that
# scripts/import-signing-certificate.sh created, and prove that no keychain
# still lists the signing identity. A signing job runs this as soon as its last
# signature is made and before it executes anything it built. It fails when the
# keychain cannot be deleted or the identity is still listed.
#
# usage: remove-signing-keychain.sh KEYCHAIN_PATH IDENTITY
set -euo pipefail

[[ $# == 2 && -n "$1" && -n "$2" ]] || {
  echo 'usage: remove-signing-keychain.sh KEYCHAIN_PATH IDENTITY' >&2
  exit 2
}
keychain=$1
identity=$2

security delete-keychain "$keychain"
test ! -e "$keychain"
# Every identity, not only valid ones: a revoked or expired key left behind is
# found too.
identities=$(security find-identity -p codesigning)
if grep -F -q -- "$identity" <<< "$identities"; then
  echo '::error::The signing identity is still readable after the signing keychain was deleted' >&2
  exit 1
fi
