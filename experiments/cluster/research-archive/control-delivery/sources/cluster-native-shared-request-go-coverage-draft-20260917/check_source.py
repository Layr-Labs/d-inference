"""Small source/metadata checks only: no compiler, fixture or workspace walk."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
UPSTREAM = BASE.parent / 'cluster-native-member-shared-requests-draft-20260917'
UPSTREAM_SHA = '1e8019ad6af9314979d5182bf61eb47671f9b22d5eb176b1cd97345c805e7c38'
ADDED = (
    'TestNativePairWorkerExactlyOneReadyNeverAdmitsCommand',
    'TestNativePairWorkerLateFramesCannotEscapeStopOrOneRelease',
    'TestNativePairWorkerAggregatePublicationMustPrecedeReplacement',
    'TestNativePairWorkerAggregateEnqueueFailureClosesOriginalConnection',
    'TestNativePairWorkerRecordAndByteBudgetsUseActualFrames',
    'TestNativePairWorkerPacketClosedFramingAndSlackBounds',
    'TestNativePairWorkerActualReadLoopRefusesAllFourKindsWithoutGrant',
)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def check():
    if sha(UPSTREAM/'manifest.json') != UPSTREAM_SHA: raise ValueError('Upstream freeze changed')
    for root in [UPSTREAM, BASE]:
        manifest = root/'manifest.json'
        if not manifest.exists():
            if root != BASE: raise ValueError('Missing upstream manifest')
            continue
        for row in json.loads(manifest.read_text())['files']:
            p = root/row['path']
            if not p.is_file() or p.is_symlink() or p.stat().st_size != row['bytes'] or sha(p) != row['sha256']:
                raise ValueError('Frozen small source changed: '+str(p))
    for p in BASE.rglob('*.py'): ast.parse(p.read_text())
    for name in ['prepare.py','run.py','owned_process.py','check_process.py','go_coverage.py']:
        if (BASE/'GoChecks'/name).read_bytes() != (UPSTREAM/'GoChecks'/name).read_bytes():
            raise ValueError('Qualified execution helper changed: '+name)
    text = (BASE/'GoChecks/inputs.py').read_text()
    for name in ADDED:
        line = '    '+repr(name)+',\n'
        if text.count(line) != 1: raise ValueError('Required test omitted or duplicated')
        text = text.replace(line,'')
    if text != (UPSTREAM/'GoChecks/inputs.py').read_text(): raise ValueError('Test selection inverse differs')
    old = (UPSTREAM/'GoChecks/guards.py').read_text()
    expected = old.replace("SOURCE_ROOTS = (BASE / 'proposed', BASE.parent / 'cluster-native-member-mesh-bridge-draft-20260917/proposed', SOURCE)",
        "UPSTREAM = BASE.parent / 'cluster-native-member-shared-requests-draft-20260917'\nUPSTREAM_SHA = '"+UPSTREAM_SHA+"'\nSOURCE_ROOTS = (BASE / 'proposed', UPSTREAM / 'proposed', BASE.parent / 'cluster-native-member-mesh-bridge-draft-20260917/proposed', SOURCE)")
    expected = expected.replace("row['sizeBytes'] or sha(p) != row['sha256']:\n            raise ValueError('Frozen input changed:",
        "row['bytes'] or sha(p) != row['sha256']:\n            raise ValueError('Frozen input changed:")
    expected = expected.replace('def verify_overlay():\n','def verify_overlay():\n    verify_frozen(UPSTREAM, UPSTREAM_SHA)\n')
    expected = expected.replace("('request', 'mesh', 'main')","('coverage', 'request', 'mesh', 'main')")
    if (BASE/'GoChecks/guards.py').read_text() != expected: raise ValueError('Authority/source layer inverse differs')
    if (BASE/'fixture-inputs.json').read_bytes() != (UPSTREAM/'fixture-inputs.json').read_bytes():
        raise ValueError('Eight cross-repository fixtures changed')
    original = json.loads((UPSTREAM/'go-source-preview.json').read_text())
    preview = json.loads((BASE/'go-source-preview.json').read_text())
    old_rows = {r['path']:r for r in original['files']}
    rows = {r['path']:r for r in preview['files']}
    proposed = list((BASE/'proposed').rglob('*'))
    files = [p for p in proposed if p.is_file()]
    if len(files) != 3 or any(p.is_symlink() or not p.name.endswith('_test.go') for p in files):
        raise ValueError('Unexpected runtime or non-test overlay')
    additions = set()
    for p in files:
        rel = p.relative_to(BASE/'proposed').as_posix(); additions.add(rel)
        if rel in old_rows or rows.get(rel) != dict(path=rel,source='coverage',sizeBytes=p.stat().st_size,sha256=sha(p)):
            raise ValueError('New test projection differs')
    if set(rows) != set(old_rows)|additions or any(rows[p] != row for p,row in old_rows.items()) or preview['packages'] != original['packages']:
        raise ValueError('Existing 1122-source/26-package closure changed')
    old_integration = json.loads((UPSTREAM/'go-integration.json').read_text())['files']
    integration = json.loads((BASE/'go-integration.json').read_text())['files']
    by_path = {r['path']:r for r in integration}
    if len(integration) != 17 or any(by_path[r['path']] != r for r in old_integration):
        raise ValueError('Inherited 14 overlays changed')
    for rel in additions:
        r = by_path[rel]; p = BASE/'proposed'/rel
        if r['mainSHA256'] is not None or r['sourcePath'] != str(p) or r['proposedSHA256'] != sha(p):
            raise ValueError('New test preimage/source binding differs')
    return dict(passed=True,upstreamManifestSHA256=UPSTREAM_SHA,newGoTestFiles=3,newTopLevelMethods=7,
        requiredNativePairMethods=32,projectedSources=1125,projectedPackages=26,
        unchangedExistingGoOverlays=14,unchangedQualifiedExecutionHelpers=5,
        sourceOnly=True,compilerExecuted=False,testsExecuted=False,materialized=False,remoteExecuted=False)

if __name__ == '__main__': print(json.dumps(check(),sort_keys=True))
