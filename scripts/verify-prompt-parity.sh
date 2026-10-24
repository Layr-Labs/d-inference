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
python3 "$ROOT/scripts/prepare-prompt-fixtures.py" \
  --manifest-source-directory "$ROOT/fixtures/prompt-contract/v1/manifests" \
  --cdn-url "${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}" \
  --artifact-root "$ARTIFACT_ROOT" --manifest-directory "$WORK/manifests"
export PROMPT_PARITY_REQUIRED=1
export PROMPT_PARITY_VECTORS="$ROOT/fixtures/prompt-contract/v1/production_vectors.json"
export PROMPT_PARITY_ARTIFACT_ROOT="$ARTIFACT_ROOT"
swift test --package-path "$ROOT/provider-swift" --configuration "$CONFIGURATION" \
  --filter ProductionPromptParityTests 2>&1 | tee "$WORK/swift.log"
# A renamed or skipped suite must never turn qualification into a silent pass.
grep -qE 'Test run with [1-9][0-9]* test|Executed [1-9][0-9]* test' "$WORK/swift.log"
if grep -qE '^[^A-Za-z0-9]*(Test|Suite) .+ skipped[.:]|with [1-9][0-9]* tests? skipped|skipped [1-9][0-9]* test' "$WORK/swift.log"; then
  echo "Public prompt qualification skipped tests" >&2
  exit 1
fi
