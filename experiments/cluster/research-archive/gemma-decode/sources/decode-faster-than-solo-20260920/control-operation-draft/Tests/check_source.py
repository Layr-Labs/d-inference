"""Exact small-source replay. No compiler, native, remote or subprocess calls."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    value = json.loads((ROOT / 'integration.json').read_bytes())
    patch = ''
    for row in value['changes']:
        old = (ROOT / 'preimages' / row['path']).read_bytes()
        new = (ROOT / 'proposed' / row['path']).read_bytes()
        assert sha(old) == row['beforeSHA256'] and sha(new) == row['afterSHA256']
        patch += ''.join(difflib.unified_diff(old.decode().splitlines(True), new.decode().splitlines(True),
            fromfile='a/' + row['path'], tofile='b/' + row['path']))
    for row in value['additions']:
        raw = (ROOT / 'proposed' / row['path']).read_bytes()
        assert sha(raw) == row['sha256'] and len(raw) == row['bytes']
        patch += ''.join(difflib.unified_diff([], raw.decode().splitlines(True),
            fromfile='/dev/null', tofile='b/' + row['path']))
    assert patch.encode() == (ROOT / 'runtime.patch').read_bytes()
    for row in value['context']:
        raw = Path(row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], row['path']
    base = ROOT / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    wire = (base / 'Gemma4BenchmarkWire.swift').read_text()
    assert wire.count('BoundedControlResourceOperation()') == 2
    assert wire.count('check: checkpoint.check') == 2
    assert 'resourceCheck: check, faultCheck: controlFaultCheck' in wire
    runtime = (base / 'Gemma4BenchmarkRuntime.swift').read_text()
    assert runtime.count('controlFaultCheck: faultChecked') == 2
    fast = runtime.split('func faultChecked() throws {', 1)[1].split('var releaseWire:', 1)[0]
    assert 'owner.checkLifetime()' in fast and 'borrowedFaultCheck()' in fast
    assert all(x not in fast for x in ['.environmentGuard', '.nativeSnapshot', 'Observation(', 'owner.check('])
    owner = (base / 'Gemma4BenchmarkResourceOwner.swift').read_text()
    original = (ROOT / 'preimages/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkResourceOwner.swift').read_text()
    begin = owner.index('\n    /// Pure owner/lifetime state only.')
    end = owner.index('\n    private func checkObservedResources', begin)
    assert owner[:begin] + owner[end:] == original
    metrics = (base / 'Gemma4BenchmarkGuardMetrics.swift').read_text()
    assert 'gemma4_guard_wall_counters_v2' in metrics
    assert 'gemma4_control_operation_resource_boundaries_v1' in metrics
    assert 'case resourceGate, faultDeadlineCheck' in metrics
    assert 'hostAllowanceBytes = 32_768' in metrics
    tests = (ROOT / 'Tests/ControlOperationChecks.swift').read_text()
    labels = [line.split('print("', 1)[1].split('"', 1)[0] for line in tests.splitlines() if 'print("PASS ' in line]
    assert labels == json.loads((ROOT / 'Tests/expected-checks.json').read_bytes())['labels']
    assert len(labels) == 17 and len(set(labels)) == 17
    contract = json.loads((ROOT / 'count-contract.json').read_bytes())
    reports = [json.loads(Path(row['path']).read_bytes()) for row in value['context']
               if row['path'].endswith('/native/worker-0.stdout')]
    def counts(snapshot):
        return {r['category']: r['count'] for r in snapshot['records']}
    def check_counts(row, prior):
        assert row['before'] == counts(prior)
        send, receive = row['sentControls'], row['receivedControls']
        inner, removed = 8 * send + 7 * receive, 8 * send + 6 * receive
        assert row['changedInternalResourceReads'] == inner
        assert row['removedFreshResourceReads'] == removed
        assert row['addedReceiveEntryResourceGates'] == receive
        expected = row['before'].copy()
        for name, delta in [('logicalGuard', receive), ('entryGuard', 2 * receive),
                            ('ownerGuard', receive), ('outerNativeFault', 8 * receive),
                            ('environmentGuard', -3 * removed), ('osSnapshot', -removed),
                            ('nativeSnapshot', -removed)]:
            expected[name] += delta
        expected['resourceGate'] = row['before']['logicalGuard'] - removed
        expected['faultDeadlineCheck'] = inner
        assert row['expected'] == expected and all(n >= 0 for n in expected.values())
        assert expected['logicalGuard'] == expected['resourceGate'] + expected['faultDeadlineCheck']
    assert len(reports) == len(contract['roles']) == 3
    for role, report in zip(contract['roles'], reports):
        assert role['mode'] == report['job']['mode']
        check_counts(role['globalCounts'], report['guardMetrics'])
        assert role['ownerResourceObservationsBefore'] == report['resources']['observationCount']
        assert role['ownerResourceObservationsExpected'] == (role['ownerResourceObservationsBefore']
            - role['globalCounts']['removedFreshResourceReads'])
        assert len(role['requests']) == len(report['samples']) == 4
        for request, sample in zip(role['requests'], report['samples']):
            assert request['ordinal'] == sample['ordinal'] and request['warmup'] == sample['warmup']
            for stage in ['prefill', 'decode']:
                check_counts(request[stage], sample['guardMetrics'][stage])
    ast.parse(Path(__file__).read_bytes(), filename=__file__)
    print(json.dumps(dict(passed=True, changedRuntimeFiles=5, addedRuntimeFiles=1,
        exactContextPins=len(value['context']), sourceInverses=True, countContractReplayed=True, expectedFoundationGroups=17,
        compilerExecuted=False, nativeExecuted=False, remoteExecuted=False, testsExecuted=False)))

if __name__ == '__main__': main()
