#!/bin/bash
# fetch_catalog_model.sh -- fetch one catalog model with the product's own
# downloader into a task-owned cache, keeping a disk floor, then check it
# against its manifest.
#
# usage: fetch_catalog_model.sh <cli-wrapper> <config.toml> <coordinator-url> <cache-dir> \
#                               <manifests-dir> <evidence-dir> <floor-GiB> <model-id>
#
# <cli-wrapper> runs the task-built darkbloom with its isolated home and state.
# The model is fetched only if, after it, at least <floor-GiB> would stay free
# on the cache's volume. A failed download is tried once more; a second failure
# is final. Exit: 0 fetched and identical, 3 skipped for the disk floor,
# 4 download failed twice, 5 fetched but the manifest check failed,
# 6 the downloader refused the model for this Mac (capability gate).
set -u
cli="$1"; config="$2"; coordinator="$3"; cache="$4"; manifests="$5"; evidence="$6"; floor="$7"; model="$8"
name="${model//\//--}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$evidence"
manifest="$manifests/$name.manifest.json"
bytes=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['total_size_bytes'])" "$manifest") || exit 64
free_kb=$(df -k "$cache" | tail -1 | awk '{print $4}')
after_gib=$(python3 -c "print(round(($free_kb*1024 - $bytes)/2**30, 1))")
echo "$(date -u +%H:%M:%SZ) $model: $(python3 -c "print(round($bytes/1e9,1))") GB; free now $(python3 -c "print(round($free_kb/2**20,1))") GiB; after fetch $after_gib GiB; floor $floor GiB"
if python3 -c "import sys; sys.exit(0 if $after_gib < $floor else 1)"; then
  echo "$model: skipped, the disk floor would be broken"; exit 3
fi
attempt=1
while true; do
  started=$SECONDS
  "$cli" models download "$model" -c "$config" --coordinator "$coordinator" > "$evidence/$name.download-attempt$attempt.log" 2>&1
  status=$?
  python3 "$here/redact.py" "$evidence/$name.download-attempt$attempt.log"
  echo "$(date -u +%H:%M:%SZ) $model: download attempt $attempt exit $status after $((SECONDS - started))s"
  [[ $status -eq 0 ]] && break
  if grep -q "permanently ineligible" "$evidence/$name.download-attempt$attempt.log"; then
    echo "$model: the downloader refuses this model on this Mac"; exit 6
  fi
  (( attempt >= 2 )) && { echo "$model: download failed twice"; exit 4; }
  attempt=$((attempt + 1))
done
snapshot=$(ls -d "$cache/models--$name/snapshots"/.revision-* "$cache/models--$name/snapshots"/* 2>/dev/null | head -1)
python3 "$here/verify_artifact.py" --manifest "$manifest" --dir "$snapshot" --receipt "$evidence/$name.manifest-check.json" || exit 5
exit 0
