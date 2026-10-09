#!/bin/bash
# usage: stage-peer.sh
# Puts this task's binaries and these scripts on the second Mac, under its
# task root: bin/gemma4 and gemma4/tools. Hold tools/lane-b.sh around it.
# Only tools/copy-uncached.sh writes there: it writes with caching off and
# hashes each file in the same pass, so nothing is read back and nothing is
# hashed again on the second Mac. Never bin/darkbloom or bin/phase.
set -uo pipefail
. "$(dirname "$0")/env.sh"
peer_setup || { echo "the second Mac does not answer over the cable"; exit 30; }
out=$E/peer-staging; mkdir -p "$out"
[ -s "$B/SHA256SUMS.txt" ] || { echo "no SHA256SUMS.txt in T/bin/gemma4: run install-binaries.sh first"; exit 31; }
# tools/copy-uncached.sh stops early, and still prints VERIFIED, when the tree
# has a subdirectory (the ssh that makes the subdirectory reads the rest of the
# file list from the loop's input). So each directory is copied on its own,
# through a temporary directory that links only that directory's own files.
copy_tree() { # copy_tree LOCAL_DIR PEER_DIR_RELATIVE LOG
  local src="$1" dst="$2" log="$3" d rel flat n=0 want
  : > "$log"; want=$(find "$src" -type f ! -name '.*' | wc -l | tr -d ' ')
  while IFS= read -r d; do
    rel=${d#"$src"}; rel=${rel#/}
    [ -n "$(find "$d" -maxdepth 1 -type f ! -name '.*' | head -1)" ] || continue
    flat=$(mktemp -d "$G/run/flat.XXXXXX")
    find "$d" -maxdepth 1 -type f ! -name '.*' -exec ln -s {} "$flat/" \;
    "$T/tools/copy-uncached.sh" "$flat" "$dst${rel:+/$rel}" < /dev/null 2>&1 | scrub > "$log.part"
    rm -rf "$flat"; cat "$log.part" >> "$log"
    tail -1 "$log.part" | grep -q '^VERIFIED' || { rm -f "$log.part"; echo "FAILED in ${rel:-.}" >> "$log"; return 1; }
    n=$((n + $(grep -c '^ok ' "$log.part"))); rm -f "$log.part"
  done < <(find "$src" -type d ! -name '.*' | sort)
  [ "$n" = "$want" ] || { echo "FAILED: $n of $want files copied" >> "$log"; return 1; }
  echo "VERIFIED: all $n files, directory by directory" >> "$log"
}
digest=$(cd "$B" && find . -type f ! -name '.*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
if [ "$(cat "$out/bin.sha256" 2>/dev/null)" = "$digest" ]; then echo "binaries already staged ($digest)"; else
  rm -f "$out/bin.sha256"
  copy_tree "$B" "$PEER_DIR/bin/gemma4" "$out/bin.log"; cat "$out/bin.log"
  tail -1 "$out/bin.log" | grep -q '^VERIFIED' || { echo "binaries not verified on the second Mac"; exit 32; }
  "${PEER[@]}" "chmod 755 $PEER_BIN/darkbloom-cluster-*" || exit 33
  echo "$digest" > "$out/bin.sha256"; cp "$B/SHA256SUMS.txt" "$out/bin-files.sha256"
fi
copy_tree "$S" "$PEER_DIR/gemma4/tools" "$out/tools.log"
tail -1 "$out/tools.log" | grep -q '^VERIFIED' || { echo "scripts not verified on the second Mac"; tail -3 "$out/tools.log"; exit 34; }
"${PEER[@]}" "chmod 755 $PEER_G/tools/*.sh $PEER_G/tools/*.py && mkdir -p $PEER_ROOT/run/gemma4/pair" || exit 35
echo "staged on the second Mac at $(date -u +%H:%M:%SZ): binaries $digest, scripts $(tail -2 "$out/tools.log" | head -1)"
