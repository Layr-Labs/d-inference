#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/register-model.yml"
PUBLISH="$ROOT_DIR/scripts/publish-model.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-publish-model.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_cmd jq
require_cmd python3
unset R2_CHUNK_BYTES

grep -Fq 'required_provider_capabilities:' "$WORKFLOW"
grep -Fq 'REQUIRED_PROVIDER_CAPABILITIES: ${{ inputs.required_provider_capabilities }}' "$WORKFLOW"

BUILD_PAYLOAD_SCRIPT="$TEST_ROOT/build-payload.sh"
awk '
  $0 == "      - name: Build registration payload" { in_step = 1; next }
  in_step && $0 == "        run: |" { in_body = 1; next }
  in_body && /^      - name:/ { exit }
  in_body { sub(/^          /, ""); print }
' "$WORKFLOW" > "$BUILD_PAYLOAD_SCRIPT"
chmod +x "$BUILD_PAYLOAD_SCRIPT"

build_payload() {
  local required_capabilities=$1
  local output_dir=$2
  mkdir -p "$output_dir"
  (
    cd "$output_dir"
    env \
      MODEL_ID=test-model \
      VERSION=v1 \
      DISPLAY_NAME='Test Model' \
      FAMILY=test \
      ARCHITECTURE=test \
      QUANTIZATION=4bit \
      CAPABILITIES_CSV=tools \
      REQUIRED_PROVIDER_CAPABILITIES="$required_capabilities" \
      MAX_CONTEXT_LENGTH=8192 \
      MAX_OUTPUT_LENGTH=1024 \
      MIN_RAM_GB=8 \
      DESCRIPTION='' \
      RUNTIME_PARAMETERS_JSON='{}' \
      METADATA_JSON='{}' \
      PROMOTE=false \
      INPUT_PRICE=1 \
      OUTPUT_PRICE=2 \
      bash -euo pipefail "$BUILD_PAYLOAD_SCRIPT" >/dev/null
  )
}

build_payload '' "$TEST_ROOT/empty"
jq -e '.required_provider_capabilities == []' "$TEST_ROOT/empty/payload.json" >/dev/null

build_payload ' apple_m5, mlx_nax,apple_m5 ' "$TEST_ROOT/normalized"
jq -e '.required_provider_capabilities == ["apple_m5", "mlx_nax"]' \
  "$TEST_ROOT/normalized/payload.json" >/dev/null

if build_payload 'apple_m5,,mlx_nax' "$TEST_ROOT/invalid" >/dev/null 2>&1; then
  printf 'Workflow payload accepted an empty required capability name.\n' >&2
  exit 1
fi
if build_payload 'Apple_M5' "$TEST_ROOT/invalid-uppercase" >/dev/null 2>&1; then
  printf 'Workflow payload accepted an invalid required capability name.\n' >&2
  exit 1
fi

FAKE_BIN="$TEST_ROOT/bin"
MODEL_DIR="$TEST_ROOT/model"
mkdir -p "$FAKE_BIN" "$MODEL_DIR"
printf '{}' > "$MODEL_DIR/config.json"
export FAKE_AWS_LOG="$TEST_ROOT/aws-args"
export FAKE_SWIFT_MARKER="$TEST_ROOT/swift-ran"

cat > "$FAKE_BIN/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
touch "$FAKE_SWIFT_MARKER"
output=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == '-o' ]]; then
    shift
    output=$1
  fi
  shift
done
python3 - "$output" <<'PYFIXTURE'
import hashlib, json, sys
h=hashlib.sha256(b'{}').hexdigest()
with open(sys.argv[1], 'w') as f:
    json.dump({'schema_version':1, 'r2_prefix':'v2/test/v1', 'file_count':1,
      'total_size_bytes':2, 'aggregate_sha256':hashlib.sha256(bytes.fromhex(h)).hexdigest(),
      'files':[{'path':'config.json','size_bytes':2,'sha256':h,'role':'config'}]}, f)
PYFIXTURE
SH
cat > "$FAKE_BIN/gcloud" <<'SH'
#!/usr/bin/env bash
printf 'test-secret\n'
SH
cat > "$FAKE_BIN/aws" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
exit 0
SH
chmod +x "$FAKE_BIN/swift" "$FAKE_BIN/gcloud" "$FAKE_BIN/aws"

run_publish() {
  local model_id=$1
  local required_capabilities=$2
  printf '%s\n%s\n%s\n%s\n' \
    "$MODEL_DIR" "$model_id" v1 "$required_capabilities" \
    | env \
        PATH="$FAKE_BIN:$PATH" \
        GCP_PROJECT=test-project \
        R2_ACCOUNT_ID=test-account \
        "$PUBLISH"
}

qwen_output="$(run_publish 'EigenLabs/Qwen3.8-27B-4bit' '')"
printf '%s\n' "$qwen_output" \
  | grep -Fq -- '-f required_provider_capabilities="apple_m5,mlx_nax"'

legacy_qwen_output="$(run_publish 'qwen3.6-35b-a3b-vl-mtp-mxfp8' '')"
printf '%s\n' "$legacy_qwen_output" \
  | grep -Fq -- '-f required_provider_capabilities=""'

: > "$FAKE_AWS_LOG"
generic_output="$(run_publish 'generic-model' '')"
printf '%s\n' "$generic_output" \
  | grep -Fq -- '-f required_provider_capabilities=""'
grep -Fq 's3://darkbloom-models/v2/test/v1/config.json ' "$FAKE_AWS_LOG"
if grep -Fq '.chunks/' "$FAKE_AWS_LOG"; then
  echo 'Default publishing unexpectedly enabled chunk transport.' >&2
  exit 1
fi

normalized_output="$(run_publish 'generic-model' ' apple_m5, mlx_nax,apple_m5 ')"
printf '%s\n' "$normalized_output" \
  | grep -Fq -- '-f required_provider_capabilities="apple_m5,mlx_nax"'

rm -f "$FAKE_SWIFT_MARKER"
if run_publish 'generic-model' 'apple_m5,,mlx_nax' >/dev/null 2>&1; then
  printf 'Publish script accepted an empty required capability name.\n' >&2
  exit 1
fi
if [[ -e "$FAKE_SWIFT_MARKER" ]]; then
  printf 'Publish script began hashing before rejecting invalid capabilities.\n' >&2
  exit 1
fi

printf 'publish model contract tests passed\n'

# Optional artifact survives the real workflow payload builder and publisher output.
export HUGGING_FACE_ARTIFACT_JSON='{"repo_id":"EigenLabs/test","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path_prefix":"mlx"}'
build_payload '' "$TEST_ROOT/hf"
jq -e '.hugging_face_artifact.repo_id == "EigenLabs/test" and .hugging_face_artifact.revision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .hugging_face_artifact.path_prefix == "mlx"' "$TEST_ROOT/hf/payload.json" >/dev/null
hf_output="$(run_publish 'test-model' '')"
printf '%s\n' "$hf_output" | grep -Fq -- "-f hugging_face_artifact_json='$HUGGING_FACE_ARTIFACT_JSON'"
export HUGGING_FACE_ARTIFACT_JSON='{"repo_id":"EigenLabs/test","revision":"main"}'
if run_publish 'test-model' '' >/dev/null 2>&1; then
  printf 'Publisher accepted mutable HF revision.\n' >&2
  exit 1
fi
unset HUGGING_FACE_ARTIFACT_JSON
build_payload '' "$TEST_ROOT/hf-legacy"
jq -e '.hugging_face_artifact == null' "$TEST_ROOT/hf-legacy/payload.json" >/dev/null
printf 'Hugging Face publish payload tests passed.\n'

: > "$FAKE_AWS_LOG"
chunk_output="$(R2_CHUNK_BYTES=1 run_publish 'generic-model' '')"
printf '%s\n' "$chunk_output" | grep -Fq -- '-f required_provider_capabilities="r2_chunked_downloads"'
grep -Fq 'config.json.chunks/000000.bin' "$FAKE_AWS_LOG"
grep -Fq 'config.json.chunks/000001.bin' "$FAKE_AWS_LOG"
grep -Fq -- '--cache-control public,max-age=31536000,immutable' "$FAKE_AWS_LOG"
if grep -Fq 's3://darkbloom-models/v2/test/v1/config.json ' "$FAKE_AWS_LOG"; then
  echo 'Chunked publisher uploaded the original file.' >&2
  exit 1
fi
tail -1 "$FAKE_AWS_LOG" | grep -Fq '/manifest.json'
printf 'R2 chunk publish tests passed.\n'
