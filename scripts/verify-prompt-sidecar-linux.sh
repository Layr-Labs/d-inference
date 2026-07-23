#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${PROMPT_SIDECAR_LINUX_BINARY:-${1:-}}"
CDN_URL="${PROMPT_PARITY_CDN_URL:-https://models.darkbloom.ai}"
VECTORS="$ROOT/fixtures/prompt-contract/v1/production_vectors.json"
MANIFEST_SNAPSHOT="$ROOT/fixtures/prompt-contract/v1/manifests"
TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/darkbloom-prompt-linux.XXXXXX")"
cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -z "$BINARY" || "$BINARY" != /* || ! -x "$BINARY" ]]; then
  echo "usage: $0 /absolute/path/to/linux-promptsidecar" >&2
  exit 1
fi

ARTIFACT_ROOT="$WORK/artifacts"
MANIFEST_DIR="$WORK/manifests"
mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd -P)"

# Materialize the immutable production prompt files directly from the checked-in
# manifest snapshots. This needs no Swift runtime and is suitable for Linux CI.
(
  cd "$ROOT/coordinator"
  go run ./cmd/promptfixtureinput \
    --manifest-source-directory "$MANIFEST_SNAPSHOT" \
    --cdn-url "$CDN_URL" \
    --artifact-root "$ARTIFACT_ROOT" \
    --manifest-directory "$MANIFEST_DIR"
)

# The static musl binary takes the Linux-only RLIMIT_AS path used in production.
# The harness covers sequential preload, all-real-contract cold singleflight,
# 25-QPS warm traffic, bounded RSS, and zero child restarts.
(
  cd "$ROOT"
  go run ./coordinator/cmd/promptsidecarloadproof \
    --binary "$BINARY" \
    --artifact-root "$ARTIFACT_ROOT" \
    --vectors "$VECTORS" \
    --duration "${PROMPT_LOAD_PROOF_DURATION:-15s}" \
    --qps "${PROMPT_LOAD_PROOF_QPS:-25}" \
    --max-rss-mib "${PROMPT_LOAD_PROOF_MAX_RSS_MIB:-1024}"
)
