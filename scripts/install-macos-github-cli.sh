#!/usr/bin/env bash
# Provision gh explicitly on minimal Apple Silicon CI images.
set -euo pipefail

if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo 'GitHub CLI bootstrap requires an Apple Silicon Mac' >&2
  exit 2
fi
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

install_root="$(mktemp -d "$RUNNER_TEMP/github-cli-2.102.0.XXXXXX")"
archive="$install_root/gh.zip"
trap 'rm -f "$archive"' EXIT
curl --fail --silent --show-error --location --retry 3 --max-time 180 \
  https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_macOS_arm64.zip \
  --output "$archive"
# Published gh_2.102.0_checksums.txt; verify before extracting or executing.
printf '%s  %s\n' \
  'da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e' \
  "$archive" | shasum -a 256 --check
/usr/bin/unzip -q "$archive" -d "$install_root"
gh_bin="$install_root/gh_2.102.0_macOS_arm64/bin"
"$gh_bin/gh" --version
printf '%s\n' "$gh_bin" >> "$GITHUB_PATH"
