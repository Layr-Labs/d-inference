#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_URL="${PROMPT_PARITY_CATALOG_URL:-https://api.darkbloom.dev/v1/models/catalog}"
CDN_URL="${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}"
EXPECTED="$ROOT/fixtures/prompt-contract/v1/production_vectors.json"
MANIFEST_SNAPSHOT="$ROOT/fixtures/prompt-contract/v1/manifests"
TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/darkbloom-prompt-parity.XXXXXX")"
cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ARTIFACT_ROOT="${PROMPT_PARITY_ARTIFACT_ROOT:-$WORK/artifacts}"
MANIFEST_DIR="$WORK/manifests"
GENERATED="$WORK/production_vectors.json"
mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd -P)"

(
  cd "$ROOT/coordinator"
  if [[ "${PROMPT_PARITY_UPDATE:-0}" == "1" ]]; then
    go run ./cmd/promptfixtureinput \
      --catalog-url "$CATALOG_URL" \
      --cdn-url "$CDN_URL" \
      --artifact-root "$ARTIFACT_ROOT" \
      --manifest-directory "$MANIFEST_DIR"
  else
    go run ./cmd/promptfixtureinput \
      --manifest-source-directory "$MANIFEST_SNAPSHOT" \
      --cdn-url "$CDN_URL" \
      --artifact-root "$ARTIFACT_ROOT" \
      --manifest-directory "$MANIFEST_DIR"
  fi
)

cargo +1.88.0 run --locked --quiet \
  --manifest-path "$ROOT/coordinator/promptsidecar/Cargo.toml" \
  --bin prompt-fixtures -- \
  --manifest-directory "$MANIFEST_DIR" \
  --artifact-root "$ARTIFACT_ROOT" \
  --cases "$ROOT/fixtures/prompt-contract/v1/corpus.json" \
  --output "$GENERATED"

if [[ "${PROMPT_PARITY_UPDATE:-0}" == "1" ]]; then
  cp "$GENERATED" "$EXPECTED"
  rm -rf "$MANIFEST_SNAPSHOT"
  mkdir -p "$MANIFEST_SNAPSHOT"
  cp "$MANIFEST_DIR"/*.json "$MANIFEST_SNAPSHOT/"
  echo "updated production prompt vectors"
else
  cmp "$EXPECTED" "$GENERATED"
  echo "production prompt parity vectors verified"
fi

PROMPT_PARITY_REQUIRED=1 \
PROMPT_PARITY_VECTORS="$GENERATED" \
PROMPT_PARITY_ARTIFACT_ROOT="$ARTIFACT_ROOT" \
  swift test \
    --package-path "$ROOT/provider-swift" \
    --filter ProductionPromptParityTests

(
  cd "$ROOT/coordinator"
  go test ./promptcontract -run TestProductionPlansConsumeSharedTokenVectors -count=1
)
cargo +1.88.0 test --locked \
  --manifest-path "$ROOT/coordinator/promptsidecar/Cargo.toml" \
  --test shared_vectors production_plans_match_shared_token_vectors
