#!/usr/bin/env bash
# Public golden-vector gate: no weights, GPU generation, or Hub credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-${SWIFT_BUILD_CONFIGURATION:-debug}}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nemotron-prompt-parity.XXXXXX")"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
WORK="$(cd "$WORK" && pwd -P)"
python3 "$ROOT/scripts/prepare-prompt-fixtures.py" \
  --manifest-source-directory "$ROOT/fixtures/prompt-contract/nemotron/manifests" \
  --cdn-url "${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}" \
  --artifact-root "$WORK/artifacts" --manifest-directory "$WORK/manifests"
contracts=("$WORK/artifacts"/*/prompt-contract.json)
[[ ${#contracts[@]} -eq 1 && -f "${contracts[0]}" ]]
export NEMOTRON_TEMPLATE_MODEL_DIR="$(dirname "${contracts[0]}")"
export PROMPT_PARITY_REQUIRED=1
(
  cd "$ROOT/provider-swift"
  ../scripts/run-nested-suite.sh NemotronTemplateParityLiveTests --configuration "$CONFIGURATION"
)
