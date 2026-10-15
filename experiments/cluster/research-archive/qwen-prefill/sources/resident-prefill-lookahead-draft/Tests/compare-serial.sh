#!/bin/bash
set -euo pipefail
task_draft="$(cd "$(dirname "$0")/.." && pwd)"
task_base="/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime"
task_new="$task_draft/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/prefill-agreement.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
for task_version in original proposed; do
  task_changes="$task_draft/originals"
  task_flags=(-D SERIAL_CHECK)
  if [[ "$task_version" == proposed ]]; then task_changes="$task_new"; task_flags=(-D LOOKAHEAD_CHECK); fi
  xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library "${task_flags[@]}" \
    "$task_base/ClusterRuntimeError.swift" "$task_base/CanonicalJSON.swift" "$task_base/WorkerJSONScanner.swift" \
    "$task_base/QwenLayerStageSchedule.swift" "$task_base/QwenLayerStageWireExpectation.swift" \
    "$task_base/QwenLayerStageGenerationRequest.swift" "$task_base/QwenLayerStageGenerationSchedule.swift" \
    "$task_changes/QwenLayerStageGenerationAgreement.swift" "$task_changes/QwenLayerStageGenerationResult.swift" \
    "$task_new/QwenGenerationPrefillPolicy.swift" "$task_draft/Tests/ExtractedCPUValues.swift" \
    "$task_draft/Tests/AgreementCheck.swift" -o "$task_build/$task_version"
  "$task_build/$task_version" > "$task_build/$task_version.stdout"
done
cmp "$task_build/original.stdout" "$task_build/proposed.stdout"
"$task_build/proposed" lookahead > "$task_build/lookahead.stdout"
python3 - "$task_build" <<'PY'
import json,sys
from pathlib import Path
b=Path(sys.argv[1]);serial=(b/'original.stdout').read_text().splitlines();ahead=(b/'lookahead.stdout').read_text().splitlines()
assert len(serial)==len(ahead)==9
for k,n in enumerate([1,513,8192]):
    old,new=json.loads(serial[k*3]),json.loads(ahead[k*3])
    assert new.pop('prefillSchedulingPolicy')=='oneChunkLookahead' and new==old
    assert serial[k*3+1]!=ahead[k*3+1]
    s,r=json.loads(serial[k*3+2]),json.loads(ahead[k*3+2])
    assert 'prefillSchedule' not in s
    assert r.pop('prefillSchedule')==dict(policy='oneChunkLookahead',rank=0,preparedAheadFrames=(n-1)//512,
        maximumPreparedBoundaries=1,pendingConsumedAtCompletion=0,decodePrefetchCount=0)
    for key in ['agreementFingerprint','tokenChainSHA256']:
        assert r.pop(key)!=s.pop(key)
    assert r==s
print('prefill-agreement: 3 saved-original serial byte comparisons and 3 opt-in identity/result cases passed')
PY
