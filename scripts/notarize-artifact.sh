#!/usr/bin/env bash
# Submit one file to Apple's notary service, wait for the verdict and fail
# unless it is Accepted. On a refusal it prints Apple's log for the submission.
# The desktop release calls it for the app and for the disk image, each in a
# step that holds the notarization credentials and runs nothing else.
#
# usage: APPLE_ID=... APPLE_APP_PASSWORD=... APPLE_TEAM_ID=... \
#          notarize-artifact.sh FILE RESULT_JSON
set -euo pipefail

[[ $# == 2 && -f "$1" ]] || { echo 'usage: notarize-artifact.sh FILE RESULT_JSON' >&2; exit 2; }
file=$1
result=$2
if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ]]; then
  echo '::error::The notarization credentials are not configured for this step' >&2
  exit 1
fi
credentials=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")

field() {
  python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except (OSError, ValueError, AttributeError):
    print("")' "$result" "$1"
}

xcrun notarytool submit "$file" "${credentials[@]}" --wait --timeout 30m --output-format json > "$result" \
  || echo "::warning::notarytool submit exited non-zero for $(basename "$file")" >&2
status=$(field status)
if [[ "$status" != Accepted ]]; then
  id=$(field id)
  echo "::error::Notarization ${id:-<no id>} of $(basename "$file") finished with status ${status:-<none>} (expected Accepted)" >&2
  if [[ -n "$id" ]]; then
    xcrun notarytool log "$id" "${credentials[@]}" >&2 || echo "::warning::Could not retrieve Apple's log for $id" >&2
  fi
  exit 1
fi
echo "Notarization $(field id) of $(basename "$file"): Accepted"
