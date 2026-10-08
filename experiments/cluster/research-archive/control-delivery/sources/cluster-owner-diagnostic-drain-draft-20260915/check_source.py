from pathlib import Path
import ast
import difflib
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'owner-retirement-controls-build-20260915'
MAIN = BASE.parent.parent / 'd-inference'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
changed, retained, chunks = [], [], []
for path in sorted((BASE / 'proposed').rglob('*.swift')):
    relative = path.relative_to(BASE / 'proposed')
    before = BASE / 'baseline' / relative
    if not before.exists() or path.read_bytes() != before.read_bytes():
        changed.append(str(relative))
        chunks += difflib.unified_diff(before.read_text().splitlines(keepends=True) if before.exists() else [],
            path.read_text().splitlines(keepends=True), fromfile='a/' + str(relative), tofile='b/' + str(relative))
    else:
        retained.append(str(relative))
assert set(changed) == {'Sources/DarkbloomClusterRemote/ClusterRemoteWorkerEndpoint.swift',
    'Sources/DarkbloomClusterRemote/ClusterOwnerDiagnostics.swift', 'Entries/controller/Controller.swift',
    'Entries/controller/OwnerTransportObservation.swift'}
for path in (BASE / 'baseline').rglob('*.swift'):
    assert path.read_bytes() == (OLD / path.relative_to(BASE / 'baseline')).read_bytes()
endpoint = (BASE / 'proposed/Sources/DarkbloomClusterRemote/ClusterRemoteWorkerEndpoint.swift').read_text()
controller = (BASE / 'proposed/Entries/controller/Controller.swift').read_text()
assert endpoint.index('diagnosticCapture.drain(diagnostics.fileHandleForReading.fileDescriptor, until: limit)') < endpoint.index('ownerEnded.leave()', endpoint.index('private func readLoop'))
assert controller.index('await endpoint.waitUntilOwnerReleased(deadline: transportDrainDeadline)') < controller.index('"endpointDiagnosticsBase64"')
assert controller.count('failure = failure ??') == 3
assert (MAIN / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterRemoteWorkerEndpoint.swift').read_bytes() == (BASE / 'baseline/Sources/DarkbloomClusterRemote/ClusterRemoteWorkerEndpoint.swift').read_bytes()
ast.parse((BASE / 'run_checks.py').read_text(), feature_version=(3, 9))
(BASE / 'runtime.patch').write_text(''.join(chunks))
paths = sorted((BASE / 'proposed').rglob('*.swift')) + sorted((BASE / 'Fixtures').glob('*.swift'))
paths += [BASE / 'build_checks.sh', BASE / 'run_checks.py', Path(__file__).resolve()]
result = {'schema': 'owner_diagnostic_drain_source_checks_v1', 'baselineManifestSHA256': sha(OLD / 'manifest.json'),
    'changedRuntime': changed, 'retainedRuntimeCount': len(retained), 'mainEndpointMatchesBaseline': True,
    'baselineAllInputsExact': True, 'drainPrecedesOwnerEnded': True, 'controllerWaitPrecedesSnapshot': True,
    'primaryFailurePreserved': True, 'python39Parse': True, 'compilerOrFixtureExecution': False,
    'runtimePatchSHA256': sha(BASE / 'runtime.patch'),
    'sources': [{'path': str(path.relative_to(BASE)), 'bytes': path.stat().st_size, 'sha256': sha(path)} for path in paths]}
(BASE / 'source-checks.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'changed': changed, 'retained': len(retained), 'sourceCheckSHA256': sha(BASE / 'source-checks.json'),
    'patchSHA256': sha(BASE / 'runtime.patch')}))
