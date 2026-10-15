"""Exact delta check; no native compilation or execution."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent
NAME='libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/NativeWorkerRuntime.swift'
REMOVED='''        guard selected == .serial else {
            throw WorkerFailure.invalid("27B native validation requires serial recording")
        }
'''
old=(BASE/'originals'/NAME).read_text();new=(BASE/'proposed'/NAME).read_text()
assert old.count(REMOVED)==1 and new==old.replace(REMOVED,'')
assert 'case .oneChunkLookahead: prefillPolicy = .oneChunkLookahead' in new
assert 'BenchmarkPrefillPolicy.parse(environment[BenchmarkPrefillPolicy.environmentName])' in new
for phrase in ('owner.recordingReadiness(prefillPolicy: prefillPolicy)',
               'owner.reserveRecording(requestID: id, request: value, prefillPolicy: prefillPolicy)',
               'owner.startRecording(requestID: id, onCommittedToken: token)',
               'result.completion.bothRequestStatesRetired'):
    assert new.count(phrase)==old.count(phrase)==1
lineage=json.loads((BASE/'lineage.json').read_bytes())
for row in lineage['sourceControls']:
    raw=Path(row['path']).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
print(json.dumps(dict(exactThreeLineRemoval=True,sharedMathAndResourcesChanged=False,
    unknownPolicyRefusalPreserved=True,recordingPolicyThreadingPreserved=True,
    actual27bLookaheadExecuted=False,compilerOrModelExecuted=False)))
