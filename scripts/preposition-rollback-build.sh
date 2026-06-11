#!/usr/bin/env bash
# Pre-position a rollback build for an alias TAKEOVER migration.
#
# A takeover alias (alias_id == the old concrete model id) has NO desired-flip
# rollback: `desired_build` may never equal `alias_id`, so "flip it back" is
# rejected by validation. The escape hatch is to make the OLD weights available
# under a DISTINCT model id BEFORE the migration — then rollback is a normal
# alias flip to that id.
#
# This script server-side-copies an existing model version's R2 objects to the
# new id's derived prefix, rewrites the manifest's model_id/r2_prefix, and
# registers the new id with the coordinator. No bytes are re-uploaded from this
# machine except the small manifest.
#
# Usage (registry fields are explicit — the OpenAI-shaped /v1/models response
# does not carry min_ram_gb/prices in registerable form):
#   R2_ACCOUNT_ID=… GCP_PROJECT=… ./scripts/preposition-rollback-build.sh \
#     <src-model-id> <src-version> <new-model-id> <coordinator-url> <publishing-key> \
#     <quantization> <min-ram-gb> <max-context> <max-output> <input-price-µ$/Mtok> <output-price-µ$/Mtok> [capabilities-csv]
#
# Example (gemma 4bit cutover; values = the absorbed 8bit registry row):
#   ./scripts/preposition-rollback-build.sh \
#     gemma-4-26b 2026-05-30-r1 gemma-4-26b-8bit https://api.darkbloom.dev "$ADMIN_KEY" \
#     8bit 36 131072 16384 30000 165000 chat
set -euo pipefail

SRC_MODEL_ID="${1:?src model id}"
SRC_VERSION="${2:?src version}"
NEW_MODEL_ID="${3:?new model id}"
COORD="${4:?coordinator url}"
PUBLISH_KEY="${5:?publishing/admin key}"
QUANT="${6:?quantization (e.g. 8bit)}"
MIN_RAM_GB="${7:?min ram gb}"
MAX_CONTEXT="${8:?max context length}"
MAX_OUTPUT="${9:?max output length}"
INPUT_PRICE="${10:?input price micro-usd per Mtok}"
OUTPUT_PRICE="${11:?output price micro-usd per Mtok}"
# Capabilities (comma-separated, e.g. "chat" or "chat,vision,tools"). MUST match
# the absorbed build's caps — if a rollback makes this id the alias primary,
# /v1/models + the OpenRouter feed derive features/modalities from it; an empty
# set would silently drop tool/vision support for clients.
CAPABILITIES="${12:-chat}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

R2_BUCKET="${R2_BUCKET:-darkbloom-models}"
R2_ACCESS_KEY_SECRET="${R2_ACCESS_KEY_SECRET:-darkbloom-r2-access-key-id}"
R2_SECRET_KEY_SECRET="${R2_SECRET_KEY_SECRET:-darkbloom-r2-secret-access-key}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required}"
: "${GCP_PROJECT:?GCP_PROJECT is required}"

# Mirror coordinator/api/model_registry_handlers.go readableModelSlug+modelR2Prefix:
# slug = sanitized id, trimmed of '-', + "--" + first 12 hex of sha256(model_id);
# prefix = v2/<slug>/<version>
slug() {
  python3 - "$1" <<'PY'
import hashlib, re, sys
mid = sys.argv[1]
s = re.sub(r'[^0-9A-Za-z._-]', '-', mid).strip('-') or "model"
print(f"{s}--{hashlib.sha256(mid.encode()).hexdigest()[:12]}")
PY
}

SRC_PREFIX="v2/$(slug "$SRC_MODEL_ID")/$SRC_VERSION"
NEW_PREFIX="v2/$(slug "$NEW_MODEL_ID")/$SRC_VERSION"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

export AWS_ACCESS_KEY_ID="$(gcloud secrets versions access latest --project "$GCP_PROJECT" --secret "$R2_ACCESS_KEY_SECRET")"
export AWS_SECRET_ACCESS_KEY="$(gcloud secrets versions access latest --project "$GCP_PROJECT" --secret "$R2_SECRET_KEY_SECRET")"

echo "Copying s3://$R2_BUCKET/$SRC_PREFIX → s3://$R2_BUCKET/$NEW_PREFIX (server-side)…"
aws s3 cp "s3://$R2_BUCKET/$SRC_PREFIX/" "s3://$R2_BUCKET/$NEW_PREFIX/" \
  --recursive --endpoint-url "$ENDPOINT" --copy-props none

echo "Rewriting manifest model_id/r2_prefix…"
TMP=$(mktemp -d)
aws s3 cp "s3://$R2_BUCKET/$NEW_PREFIX/manifest.json" "$TMP/manifest.json" --endpoint-url "$ENDPOINT"
python3 - "$TMP/manifest.json" "$NEW_MODEL_ID" "$NEW_PREFIX" <<'PY'
import json, sys
path, new_id, new_prefix = sys.argv[1:4]
m = json.load(open(path))
m["model_id"] = new_id
if "r2_prefix" in m: m["r2_prefix"] = new_prefix
json.dump(m, open(path, "w"), indent=2)
PY
aws s3 cp "$TMP/manifest.json" "s3://$R2_BUCKET/$NEW_PREFIX/manifest.json" --endpoint-url "$ENDPOINT"

echo "Registering $NEW_MODEL_ID with the coordinator…"
python3 - "$NEW_MODEL_ID" "$SRC_VERSION" "$QUANT" "$MIN_RAM_GB" "$MAX_CONTEXT" "$MAX_OUTPUT" "$INPUT_PRICE" "$OUTPUT_PRICE" "$CAPABILITIES" <<'PY' > "$TMP/register.json"
import json, sys
new_id, version, quant, min_ram, max_ctx, max_out, in_p, out_p, caps = sys.argv[1:10]
print(json.dumps({
  "model_id": new_id,
  "version": version,
  "display_name": new_id + " (rollback)",
  "quantization": quant,
  "min_ram_gb": int(min_ram),
  "max_context_length": int(max_ctx),
  "max_output_length": int(max_out),
  "input_price": int(in_p),
  "output_price": int(out_p),
  "capabilities": [c for c in caps.split(",") if c],
}))
PY
curl -fsS -X POST "$COORD/v1/admin/models/register" \
  -H "Authorization: Bearer $PUBLISH_KEY" -H "Content-Type: application/json" \
  --data @"$TMP/register.json"
echo
echo "Promoting $NEW_MODEL_ID $SRC_VERSION…"
curl -fsS -X POST "$COORD/v1/admin/models/$NEW_MODEL_ID/promote" \
  -H "Authorization: Bearer $PUBLISH_KEY" -H "Content-Type: application/json" \
  --data "{\"version\": \"$SRC_VERSION\"}"
echo
echo "Done. Rollback is now a normal alias flip: desired_build=$NEW_MODEL_ID."
rm -rf "$TMP"
