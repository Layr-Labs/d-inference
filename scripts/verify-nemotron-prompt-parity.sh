#!/usr/bin/env bash
# Metadata-only gate: no model weights, GPU generation, or Hub credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nemotron-prompt-parity.XXXXXX")"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
WORK="$(cd "$WORK" && pwd -P)"

cd "$ROOT"
go run ./coordinator/cmd/promptfixtureinput \
  --manifest-source-directory fixtures/prompt-contract/nemotron/manifests \
  --artifact-root "$WORK/artifacts" --manifest-directory "$WORK/manifests"
contracts=("$WORK/artifacts"/*/prompt-contract.json)
[[ ${#contracts[@]} -eq 1 && -f "${contracts[0]}" ]]
export NEMOTRON_TEMPLATE_MODEL_DIR="$(dirname "${contracts[0]}")"

(
  cd provider-swift
  ../scripts/run-nested-suite.sh NemotronTemplateParityLiveTests
)
cargo +1.88.0 test --locked --manifest-path coordinator/promptsidecar/Cargo.toml \
  --lib render::tests::nemotron_reference_corpus_matches_prompt_bytes_and_tokens -- --exact --ignored
cargo +1.88.0 test --locked --manifest-path coordinator/promptsidecar/Cargo.toml \
  --test nemotron_prompt_edges -- --include-ignored
