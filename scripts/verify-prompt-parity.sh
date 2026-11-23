#!/usr/bin/env bash
# Public Swift qualification against committed golden vectors, not regeneration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-${SWIFT_BUILD_CONFIGURATION:-debug}}"
if [[ "${PROMPT_PARITY_UPDATE:-0}" != "0" ]]; then
  echo "Vector regeneration and cross-implementation proof belong in darkbloom-platform." >&2
  exit 2
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-prompt-parity.XXXXXX")"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
WORK="$(cd "$WORK" && pwd -P)"
ARTIFACT_ROOT="${PROMPT_PARITY_ARTIFACT_ROOT:-$WORK/artifacts}"
mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd -P)"
# CI keeps verified downloads between runs (PROMPT_PARITY_DOWNLOAD_CACHE); every
# byte restored from it is checked against its pin, and a mismatch downloads.
download_cache=()
[[ -z "${PROMPT_PARITY_DOWNLOAD_CACHE:-}" ]] || download_cache=(--download-cache "$PROMPT_PARITY_DOWNLOAD_CACHE")
python3 "$ROOT/scripts/prepare-prompt-fixtures.py" \
  --manifest-source-directory "$ROOT/fixtures/prompt-contract/v1/manifests" \
  --cdn-url "${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}" \
  --artifact-root "$ARTIFACT_ROOT" --manifest-directory "$WORK/manifests" \
  ${download_cache[@]+"${download_cache[@]}"}
export PROMPT_PARITY_REQUIRED=1
export PROMPT_PARITY_VECTORS="$ROOT/fixtures/prompt-contract/v1/production_vectors.json"
export PROMPT_PARITY_ARTIFACT_ROOT="$ARTIFACT_ROOT"
# CI runs this against the test build it already made (PROMPT_PARITY_SKIP_BUILD=1).
[[ "${PROMPT_PARITY_SKIP_BUILD:-0}" != 0 ]] ||
  swift build --package-path "$ROOT/provider-swift" --configuration "$CONFIGURATION" --build-tests
# A renamed or skipped suite must never turn qualification into a silent pass:
# run-nested-suite.sh fails a run that executes no test or skips one.
(
  cd "$ROOT/provider-swift"
  ../scripts/run-nested-suite.sh ProductionPromptParityTests --configuration "$CONFIGURATION"
)
