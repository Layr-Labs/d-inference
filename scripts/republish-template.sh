#!/usr/bin/env bash
# Republish a registry model as a NEW VERSION with its chat template extracted
# into a standalone chat_template.jinja.
#
# Why: the provider's SSD prefix cache (PromptContractIdentity) hard-requires a
# standalone chat_template.jinja in the model snapshot. Models published with
# the template only embedded in tokenizer_config.json report cache_init_failed
# on every slot. The fix is a new version of the same model id: identical
# weight objects (server-side R2 copies, no bytes downloaded), plus the
# extracted template file, plus a manifest whose aggregate is recomputed from
# the old manifest's per-file digests.
#
# DEFAULT MODE IS DRY-RUN: fetches + local build only, prints the exact
# commands that WOULD run. Pass --execute to arm the R2 copies and uploads.
# Registration + promotion always stays a human step (the gh command is
# printed, never run).
#
# The old prefix is never mutated and nothing is ever deleted.
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

usage() {
  cat >&2 <<'EOF'
Usage: republish-template.sh [MODEL_ID] [NEW_VERSION] [--dry-run|--execute]

  MODEL_ID     registry model id (e.g. mlx-community/foo); prompted if omitted
  NEW_VERSION  new version tag, no slashes (e.g. 2026-07-23-r2); prompted if omitted
  --dry-run    (default) print the copy/upload/register commands without running them
  --execute    perform the R2 server-side copies and uploads (registration stays manual)

Environment:
  COORDINATOR_URL       coordinator base URL   (default https://api.darkbloom.dev)
  MODEL_CDN_BASE_URL    model CDN base URL     (default https://models.darkbloom.ai)
  R2_BUCKET             R2 bucket              (default darkbloom-models)
  R2_ACCOUNT_ID         Cloudflare account id  (required with --execute)
  GCP_PROJECT           GCP project for Secret Manager (required with --execute)
  R2_ACCESS_KEY_SECRET  Secret Manager name    (default darkbloom-r2-access-key-id)
  R2_SECRET_KEY_SECRET  Secret Manager name    (default darkbloom-r2-secret-access-key)
EOF
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COORDINATOR_URL="${COORDINATOR_URL:-https://api.darkbloom.dev}"
MODEL_CDN_BASE_URL="${MODEL_CDN_BASE_URL:-https://models.darkbloom.ai}"
R2_ACCESS_KEY_SECRET="${R2_ACCESS_KEY_SECRET:-darkbloom-r2-access-key-id}"
R2_SECRET_KEY_SECRET="${R2_SECRET_KEY_SECRET:-darkbloom-r2-secret-access-key}"
R2_BUCKET="${R2_BUCKET:-darkbloom-models}"
MAX_ARTIFACT_BYTES=100000000 # small-artifact cap; weights are never downloaded

EXECUTE=0
MODEL_ID=""
NEW_VERSION=""
for arg in "$@"; do
  case "$arg" in
    --execute) EXECUTE=1 ;;
    --dry-run) EXECUTE=0 ;;
    -h|--help) usage ;;
    -*) printf 'Unknown flag: %s\n' "$arg" >&2; usage ;;
    *)
      if [[ -z "$MODEL_ID" ]]; then MODEL_ID="$arg"
      elif [[ -z "$NEW_VERSION" ]]; then NEW_VERSION="$arg"
      else printf 'Unexpected argument: %s\n' "$arg" >&2; usage
      fi
      ;;
  esac
done

require_cmd curl
require_cmd jq
require_cmd swift
require_cmd python3

if [[ -z "$MODEL_ID" ]]; then
  read -r -p "Model id (e.g. mlx-community/foo): " MODEL_ID
fi
if [[ -z "$NEW_VERSION" ]]; then
  read -r -p "New version (no slashes, e.g. 2026-07-23-r2): " NEW_VERSION
fi
if [[ -z "$MODEL_ID" ]]; then
  printf 'Model id is required.\n' >&2
  exit 1
fi
# Mirror ManifestBuilder.validateVersion: non-empty, [A-Za-z0-9._-] only
# (which excludes "/"), no "..".
if [[ -z "$NEW_VERSION" || ! "$NEW_VERSION" =~ ^[A-Za-z0-9._-]+$ || "$NEW_VERSION" == *".."* ]]; then
  printf 'New version must be non-empty, use only [A-Za-z0-9._-], and contain no "..": %s\n' "$NEW_VERSION" >&2
  exit 1
fi

if [[ "$EXECUTE" == 1 ]]; then
  require_cmd aws
  require_cmd gcloud
  if [[ -z "${GCP_PROJECT:-}" ]]; then
    GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  if [[ -z "${GCP_PROJECT:-}" ]]; then
    printf 'GCP_PROJECT is required or must be configured in gcloud.\n' >&2
    exit 1
  fi
  if [[ -z "${R2_ACCOUNT_ID:-}" ]]; then
    printf 'R2_ACCOUNT_ID is required with --execute.\n' >&2
    exit 1
  fi
  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
else
  # Dry-run never needs credentials; show a placeholder endpoint if unset.
  R2_ENDPOINT="https://${R2_ACCOUNT_ID:-<R2_ACCOUNT_ID>}.r2.cloudflarestorage.com"
fi

# ---------------------------------------------------------------------------
# 1) Catalog record -> current version + r2_prefix -> old manifest.
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d -t darkbloom-republish.XXXXXX)"
ARTIFACTS_DIR="$WORK_DIR/artifacts"
OLD_MANIFEST="$WORK_DIR/manifest.old.json"
NEW_MANIFEST="$WORK_DIR/manifest.json"
TEMPLATE_FILE="$WORK_DIR/chat_template.jinja"
mkdir -p "$ARTIFACTS_DIR"
printf 'Working directory (kept for inspection): %s\n' "$WORK_DIR"

CATALOG_URL="$COORDINATOR_URL/v1/models/catalog/$MODEL_ID"
printf 'Fetching catalog record: %s\n' "$CATALOG_URL"
CATALOG_JSON="$WORK_DIR/catalog.json"
if ! curl -fsS "$CATALOG_URL" -o "$CATALOG_JSON"; then
  printf 'Model %s not found in the coordinator catalog (%s).\n' "$MODEL_ID" "$CATALOG_URL" >&2
  exit 1
fi

OLD_VERSION="$(jq -r '.version // empty' "$CATALOG_JSON")"
OLD_PREFIX="$(jq -r '.r2_prefix // empty' "$CATALOG_JSON")"
if [[ -z "$OLD_VERSION" || -z "$OLD_PREFIX" ]]; then
  printf 'Catalog record for %s has no active version/r2_prefix — nothing to republish.\n' "$MODEL_ID" >&2
  exit 1
fi
if [[ "$NEW_VERSION" == "$OLD_VERSION" ]]; then
  printf 'New version %s equals the current active version — republishing onto the same prefix would mutate it. Pick a fresh version.\n' "$NEW_VERSION" >&2
  exit 1
fi
printf 'Current active version: %s (prefix %s)\n' "$OLD_VERSION" "$OLD_PREFIX"

printf 'Fetching old manifest: %s/%s/manifest.json\n' "$MODEL_CDN_BASE_URL" "$OLD_PREFIX"
curl -fsS "$MODEL_CDN_BASE_URL/$OLD_PREFIX/manifest.json" -o "$OLD_MANIFEST"

# The manifest must describe exactly what the catalog told us.
jq -e --arg id "$MODEL_ID" --arg v "$OLD_VERSION" --arg p "$OLD_PREFIX" \
  '.model_id == $id and .version == $v and .r2_prefix == $p' "$OLD_MANIFEST" >/dev/null || {
  printf 'Old manifest model_id/version/r2_prefix does not match the catalog record — refusing to continue.\n' >&2
  exit 1
}

# Fail fast with a friendly message; the Swift tool re-checks authoritatively.
if jq -e '.files[] | select(.path == "chat_template.jinja")' "$OLD_MANIFEST" >/dev/null; then
  printf 'Model %s (version %s) already ships a standalone chat_template.jinja — nothing to republish.\n' "$MODEL_ID" "$OLD_VERSION" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2) Download ONLY the small config/tokenizer/template artifacts.
# ---------------------------------------------------------------------------
WEIGHT_SUMMARY="$(jq -r --argjson cap "$MAX_ARTIFACT_BYTES" \
  '[.files[] | select((.role == "config" or .role == "tokenizer" or .role == "template") and .size_bytes < $cap | not)] | "\(length) file(s), \(([.[].size_bytes] | add // 0) / 1e9 | floor) GB"' \
  "$OLD_MANIFEST")"
printf 'Skipping weight/large files entirely: %s (server-side copied later)\n' "$WEIGHT_SUMMARY"

DOWNLOADED=0
while IFS=$'\t' read -r rel_path expected_sha; do
  dest="$ARTIFACTS_DIR/$rel_path"
  mkdir -p "$(dirname "$dest")"
  printf 'Downloading %s\n' "$rel_path"
  curl -fsS "$MODEL_CDN_BASE_URL/$OLD_PREFIX/$rel_path" -o "$dest"
  actual_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$dest")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'SHA-256 mismatch for %s: manifest %s, downloaded %s\n' "$rel_path" "$expected_sha" "$actual_sha" >&2
    exit 1
  fi
  DOWNLOADED=$((DOWNLOADED + 1))
done < <(jq -r --argjson cap "$MAX_ARTIFACT_BYTES" \
  '.files[] | select((.role == "config" or .role == "tokenizer" or .role == "template") and .size_bytes < $cap) | [.path, .sha256] | @tsv' \
  "$OLD_MANIFEST")

if [[ "$DOWNLOADED" == 0 ]]; then
  printf 'No config/tokenizer/template artifacts listed in the old manifest — cannot extract a template.\n' >&2
  exit 1
fi
printf 'Downloaded %d small artifact(s) into %s\n' "$DOWNLOADED" "$ARTIFACTS_DIR"

# ---------------------------------------------------------------------------
# 3) Extract the template + build the new manifest (local, digests-only).
# ---------------------------------------------------------------------------
printf 'Running darkbloom-publish extract-template...\n'
(cd "$ROOT_DIR/provider-swift" && swift run -c release darkbloom-publish extract-template \
  --manifest "$OLD_MANIFEST" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --new-version "$NEW_VERSION" \
  --output "$NEW_MANIFEST" \
  --template-output "$TEMPLATE_FILE")

NEW_PREFIX="$(jq -r '.r2_prefix' "$NEW_MANIFEST")"

# Refuse to clobber an existing published version at the target prefix.
if curl -fsS -o /dev/null "$MODEL_CDN_BASE_URL/$NEW_PREFIX/manifest.json" 2>/dev/null; then
  printf 'Target prefix %s already has a manifest.json — refusing to overwrite an existing version.\n' "$NEW_PREFIX" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4) Copy/upload plan — printed in dry-run, executed with --execute.
#    Old-prefix objects are ONLY ever the SOURCE of server-side copies.
# ---------------------------------------------------------------------------
printf '\nNew manifest summary:\n'
jq '{model_id, version, r2_prefix, aggregate_sha256, total_size_bytes, file_count}' "$NEW_MANIFEST"

printf '\nExtracted template (first 20 lines of %s):\n' "$TEMPLATE_FILE"
head -20 "$TEMPLATE_FILE"
printf '\n--- end of template preview ---\n'

run_or_print() {
  if [[ "$EXECUTE" == 1 ]]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
    "$@"
  else
    printf ' '; printf ' %q' "$@"; printf '\n'
  fi
}

if [[ "$EXECUTE" == 1 ]]; then
  printf '\nFetching R2 credentials from GCP Secret Manager...\n'
  AWS_ACCESS_KEY_ID="$(gcloud secrets versions access latest --project "$GCP_PROJECT" --secret "$R2_ACCESS_KEY_SECRET")"
  AWS_SECRET_ACCESS_KEY="$(gcloud secrets versions access latest --project "$GCP_PROJECT" --secret "$R2_SECRET_KEY_SECRET")"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION="auto"
  printf 'Server-side copying %s -> %s (no bytes downloaded)...\n' "$OLD_PREFIX" "$NEW_PREFIX"
else
  printf '\nDRY RUN — the following commands WOULD run with --execute:\n\n'
  printf '# server-side copies (CopyObject within bucket %s; old prefix is read-only source)\n' "$R2_BUCKET"
fi

while IFS= read -r rel_path; do
  run_or_print aws s3 cp \
    "s3://$R2_BUCKET/$OLD_PREFIX/$rel_path" \
    "s3://$R2_BUCKET/$NEW_PREFIX/$rel_path" \
    --endpoint-url "$R2_ENDPOINT" --only-show-errors
done < <(jq -r '.files[].path' "$OLD_MANIFEST")

if [[ "$EXECUTE" == 0 ]]; then
  printf '\n# new-file uploads (manifest.json LAST — it is the publish commit point)\n'
fi
run_or_print aws s3 cp "$TEMPLATE_FILE" \
  "s3://$R2_BUCKET/$NEW_PREFIX/chat_template.jinja" \
  --endpoint-url "$R2_ENDPOINT" --only-show-errors
run_or_print aws s3 cp "$NEW_MANIFEST" \
  "s3://$R2_BUCKET/$NEW_PREFIX/manifest.json" \
  --endpoint-url "$R2_ENDPOINT" --only-show-errors

if [[ "$EXECUTE" == 1 ]]; then
  printf '\nUpload complete. Verify: %s/%s/manifest.json\n' "$MODEL_CDN_BASE_URL" "$NEW_PREFIX"
fi

# ---------------------------------------------------------------------------
# 5) Registration + promotion stays a human step: print the exact command.
#    Prefilled from the live catalog record and public pricing endpoint.
# ---------------------------------------------------------------------------
DISPLAY_NAME="$(jq -r '.display_name // .id' "$CATALOG_JSON")"
FAMILY="$(jq -r '.family // ""' "$CATALOG_JSON")"
ARCHITECTURE="$(jq -r '.architecture // ""' "$CATALOG_JSON")"
QUANTIZATION="$(jq -r '.quantization // ""' "$CATALOG_JSON")"
CAPABILITIES_CSV="$(jq -r '(.capabilities // []) | join(",")' "$CATALOG_JSON")"
MAX_CONTEXT="$(jq -r '.max_context_length // 0' "$CATALOG_JSON")"
MAX_OUTPUT="$(jq -r '.max_output_length // 0' "$CATALOG_JSON")"
MIN_RAM_GB="$(jq -r '.min_ram_gb // 0' "$CATALOG_JSON")"
DESCRIPTION="$(jq -r '.description // ""' "$CATALOG_JSON")"
RUNTIME_PARAMS="$(jq -c '.runtime_parameters // {}' "$CATALOG_JSON")"
METADATA="$(jq -c '.metadata // {}' "$CATALOG_JSON")"
INPUT_PRICE="$(curl -fsS "$COORDINATOR_URL/v1/pricing" 2>/dev/null | jq -r --arg m "$MODEL_ID" '.prices[]? | select(.model == $m) | .input_price' || true)"
OUTPUT_PRICE="$(curl -fsS "$COORDINATOR_URL/v1/pricing" 2>/dev/null | jq -r --arg m "$MODEL_ID" '.prices[]? | select(.model == $m) | .output_price' || true)"

cat <<EOF

Next (human step) — register the new version, verify a provider converges,
then promote:

  gh workflow run register-model.yml \\
    -f model_id="$MODEL_ID" \\
    -f version="$NEW_VERSION" \\
    -f display_name="$DISPLAY_NAME" \\
    -f family="$FAMILY" \\
    -f architecture="$ARCHITECTURE" \\
    -f quantization="$QUANTIZATION" \\
    -f capabilities_csv="$CAPABILITIES_CSV" \\
    -f max_context_length="$MAX_CONTEXT" \\
    -f max_output_length="$MAX_OUTPUT" \\
    -f min_ram_gb="$MIN_RAM_GB" \\
    -f description="$DESCRIPTION" \\
    -f runtime_parameters_json='$RUNTIME_PARAMS' \\
    -f metadata_json='$METADATA' \\
    -f input_price="${INPUT_PRICE:-<input_price micro-USD per 1M tokens>}" \\
    -f output_price="${OUTPUT_PRICE:-<output_price micro-USD per 1M tokens>}" \\
    -f promote="false" \\
    -f coordinator_url="$COORDINATOR_URL"

Promotion (after verifying the registered version):
  POST $COORDINATOR_URL/v1/admin/models/$MODEL_ID/promote {"version": "$NEW_VERSION"}
  (scripts/admin.sh, or re-run the workflow with promote=true)

EOF

if [[ "$EXECUTE" == 0 ]]; then
  printf 'DRY RUN complete — nothing was uploaded or copied. Re-run with --execute to arm.\n'
fi
