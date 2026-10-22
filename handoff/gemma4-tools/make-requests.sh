#!/bin/bash
# usage: make-requests.sh BIN_DIR MODEL_DIR OUT_DIR PROMPT_TEXT_DIR
# The ladder's three requests (30, 4,096 and 8,192 prompt tokens, no stop IDs)
# and the product comparison's three (text as written, the product's stop IDs).
set -euo pipefail
bin="$1"; model="$2"; out="$3"; texts="$4"
Q="$texts"
mkdir -p "$out"
pc="$bin/darkbloom-cluster-pair-check"
[ -e "$out/short.json" ] || "$pc" request --output "$out/short.json" --chunk-size 512 --output-count 64 --model-dir "$model" --user-text-file "$Q/short-question.txt"
[ -e "$out/p4k.json" ] || "$pc" request --output "$out/p4k.json" --chunk-size 512 --output-count 64 --model-dir "$model" --user-text-file "$Q/long-passage.txt" --prompt-tokens 4096
[ -e "$out/p8k.json" ] || "$pc" request --output "$out/p8k.json" --chunk-size 512 --output-count 128 --model-dir "$model" --user-text-file "$Q/long-passage.txt" --prompt-tokens 8192
[ -e "$out/fault128.json" ] || "$pc" request --output "$out/fault128.json" --chunk-size 512 --output-count 128 --model-dir "$model" --user-text-file "$Q/short-question.txt"
for name in prod-short prod-4k prod-8k; do
  [ -e "$out/$name.json" ] || "$pc" request --output "$out/$name.json" --chunk-size 512 --output-count 128 --model-dir "$model" --user-text-file "$texts/$name.txt" --stop-token-ids 1,50,106
done
python3 - "$out" <<'PY'
import json,sys,glob,os
for f in sorted(glob.glob(sys.argv[1]+"/*.json")):
    r=json.load(open(f)); s=r["promptSource"]
    print(os.path.basename(f), r["modelID"], "prompt", len(r["promptTokenIDs"]), "out", r["outputCount"], "stops", r["stopTokenIDs"], "matchesTemplate", s.get("matchesArtifactChatTemplate"), "first", r["promptTokenIDs"][:4], "last", r["promptTokenIDs"][-6:])
PY
