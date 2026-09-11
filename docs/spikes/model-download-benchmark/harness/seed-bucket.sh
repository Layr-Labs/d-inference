#!/bin/sh
# Drives the setup Worker to materialise every synthetic object. Idempotent.
set -eu
: "${SETUP_URL:?}" "${SETUP_TOKEN:?}"
SHARDS=${SHARD_COUNT:-4}; PARTS=${CHUNKS_PER_SHARD:-16}
post() { curl -fsS --max-time 600 -X POST -H "X-Setup-Token: $SETUP_TOKEN" "$@"; }
s=1; while [ $s -le $SHARDS ]; do
  p=1; while [ $p -le $PARTS ]; do echo "chunk $s/$p: $(post "$SETUP_URL/chunk/$s/$p")"; p=$((p+1)); done
  init=$(post "$SETUP_URL/large/$s/init"); echo "large $s init: $init"
  if echo "$init" | grep -q '"created":true'; then
    uid=$(echo "$init" | sed -n 's/.*"uploadId":"\([^"]*\)".*/\1/p'); parts="["
    p=1; while [ $p -le $PARTS ]; do r=$(post "$SETUP_URL/large/$s/part/$p?uploadId=$uid"); echo "large $s part $p: $r"; parts="$parts$( [ $p -gt 1 ] && echo , )$(echo "$r" | sed 's/.*"partNumber":\([0-9]*\),"etag":"\([^"]*\)".*/{"partNumber":\1,"etag":"\2"}/')"; p=$((p+1)); done
    echo "large $s complete: $(post -H 'Content-Type: application/json' -d "{\"uploadId\":\"$uid\",\"parts\":$parts]}" "$SETUP_URL/large/$s/complete")"
  fi
  s=$((s+1))
done
curl -fsS -H "X-Setup-Token: $SETUP_TOKEN" "$SETUP_URL/status"
