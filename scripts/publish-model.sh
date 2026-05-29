#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_cmd swift
require_cmd aws
require_cmd gcloud
require_cmd python3
require_cmd xargs

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R2_ACCESS_KEY_SECRET="${R2_ACCESS_KEY_SECRET:-darkbloom-r2-access-key-id}"
R2_SECRET_KEY_SECRET="${R2_SECRET_KEY_SECRET:-darkbloom-r2-secret-access-key}"
R2_BUCKET="${R2_BUCKET:-darkbloom-models}"

read -r -p "Model directory: " MODEL_DIR
read -r -p "Model id (for example mlx-community/foo): " MODEL_ID
read -r -p "Version (no slashes): " VERSION

if [[ ! -d "$MODEL_DIR" ]]; then
  printf 'Model directory does not exist: %s\n' "$MODEL_DIR" >&2
  exit 1
fi
if [[ -z "$MODEL_ID" || -z "$VERSION" || "$VERSION" == *"/"* ]]; then
  printf 'Model id and version are required; version must not contain /.\n' >&2
  exit 1
fi

if [[ -z "${GCP_PROJECT:-}" ]]; then
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$GCP_PROJECT" ]]; then
  printf 'GCP_PROJECT is required or must be configured in gcloud.\n' >&2
  exit 1
fi
if [[ -z "${R2_ACCOUNT_ID:-}" ]]; then
  printf 'R2_ACCOUNT_ID is required.\n' >&2
  exit 1
fi

MANIFEST="$(mktemp -t darkbloom-model-manifest.XXXXXX.json)"
trap 'rm -f "$MANIFEST"' EXIT

printf 'Hashing model into manifest...\n'
(cd "$ROOT_DIR/provider-swift" && swift run -c release darkbloom-publish hash "$MODEL_DIR" --id "$MODEL_ID" --version "$VERSION" -o "$MANIFEST")

R2_PREFIX="$(python3 - "$MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    print(json.load(f)['r2_prefix'])
PY
)"

printf 'Fetching R2 credentials from GCP Secret Manager...\n'
export AWS_ACCESS_KEY_ID="$(gcloud secrets versions access latest --project "$GCP_PROJECT" --secret "$R2_ACCESS_KEY_SECRET")"
export AWS_SECRET_ACCESS_KEY="$(gcloud secrets versions access latest --project "$GCP_PROJECT" --secret "$R2_SECRET_KEY_SECRET")"
export AWS_DEFAULT_REGION="auto"
export R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

printf 'Uploading model files to s3://%s/%s with concurrency 8...\n' "$R2_BUCKET" "$R2_PREFIX"
python3 - "$MANIFEST" "$MODEL_DIR" "$R2_BUCKET" "$R2_PREFIX" <<'PY'
import concurrent.futures
import json
import os
import subprocess
import sys
manifest_path, model_dir, bucket, prefix = sys.argv[1:]
endpoint = os.environ["R2_ENDPOINT"]
with open(manifest_path, 'r', encoding='utf-8') as f:
    manifest = json.load(f)

def upload(item):
    rel = item['path']
    src = os.path.join(model_dir, rel)
    dst = f"s3://{bucket}/{prefix}/{rel}"
    subprocess.run(["aws", "s3", "cp", src, dst, "--endpoint-url", endpoint, "--only-show-errors"], check=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
    list(executor.map(upload, manifest['files']))
PY

printf 'Uploading manifest last...\n'
aws s3 cp "$MANIFEST" "s3://${R2_BUCKET}/${R2_PREFIX}/manifest.json" --endpoint-url "$R2_ENDPOINT" --only-show-errors

cat <<EOF

Upload complete.

Register with GitHub Actions:
  gh workflow run register-model.yml \
    -f model_id="$MODEL_ID" \
    -f version="$VERSION" \
    -f display_name="<display name>" \
    -f family="<family>" \
    -f architecture="<architecture>" \
    -f quantization="<quantization>" \
    -f capabilities_csv="tools,reasoning" \
    -f max_context_length="<max context tokens>" \
    -f max_output_length="<max output tokens>" \
    -f min_ram_gb="<minimum RAM GB>" \
    -f description="" \
    -f runtime_parameters_json='{}' \
    -f metadata_json='{}' \
    -f promote="false" \
    -f coordinator_url="https://api.darkbloom.dev"
EOF
