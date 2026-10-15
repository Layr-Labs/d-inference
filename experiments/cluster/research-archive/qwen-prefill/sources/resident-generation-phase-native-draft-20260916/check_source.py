"""Small source/metadata checks. Never executes fixtures or materializes a cache."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
ANCESTOR = BASE.parent / 'qwen27b-lookahead-native-build-20260915'
OBSERVER = BASE.parent / 'resident-generation-observation-draft-20260916'
REL = Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
WORKER = Path('libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def one(source, old, new=''):
    assert source.count(old) == 1, (old, source.count(old))
    return source.replace(old, new)

def body(source, start, indent=''):
    first = source.index(start)
    last = source.index('\n' + indent + '}', first) + len(indent) + 2
    return source[first:last]

def main():
    checks, rows, native_patch, increment_patch = [], [], [], []
    observer_manifest = (OBSERVER / 'manifest.json').read_bytes()
    assert sha(observer_manifest) == '849e7de72cbd0aa98d88bb1a67d63e64675202aa0e5b3da208c61f5f3c48f7d5'
    for row in json.loads(observer_manifest)['members']:
        value = (OBSERVER / row['path']).read_bytes()
        assert len(value) == row['bytes'] and sha(value) == row['sha256']
    checks.append('frozen observer ancestry members exact')
    source_rows = json.loads((ANCESTOR / 'source-snapshot-1.json').read_bytes())['members']
    assert len(source_rows) == 3040
    source_index = {row['path']: row for row in source_rows}
    for file in sorted((BASE / 'proposed').rglob('*.swift')):
        path = file.relative_to(BASE / 'proposed')
        value = file.read_bytes()
        prior = BASE / 'original' / path
        observer = OBSERVER / 'proposed' / path
        native = ANCESTOR / 'workspace' / path
        old = native.read_bytes() if str(path) in source_index else b''
        if old:
            assert sha(old) == source_index[str(path)]['sha256']
        if prior.exists():
            expected = observer.read_bytes() if observer.exists() else old
            assert prior.read_bytes() == expected
        effective = prior.read_bytes() if prior.exists() else b''
        rows.append(dict(path=str(path), proposedSHA256=sha(value),
            c35cSHA256=sha(old) if old else None,
            effectivePreimageSHA256=sha(effective) if effective else None,
            newToC35c=not bool(old)))
        for target, before in [(native_patch, old), (increment_patch, effective)]:
            target.extend(difflib.unified_diff(before.decode().splitlines(True), value.decode().splitlines(True),
                fromfile='a/' + str(path) if before else '/dev/null', tofile='b/' + str(path)))
    assert len(rows) == 18 and sum(row['newToC35c'] for row in rows) == 10
    checks.append('18 explicit overlays, 8 changed c35c paths and 10 new paths')
    for name in ['QwenGenerationLookaheadProducer.swift', 'QwenLayerStageGenerationTransport.swift',
                 'QwenGenerationPhaseObservation.swift', 'QwenGenerationPhaseHook.swift']:
        assert (BASE / 'proposed' / REL / name).read_bytes() == (OBSERVER / 'proposed' / REL / name).read_bytes()
    driver = (BASE / 'proposed' / REL / 'QwenLayerStageGenerationDriver.swift').read_text()
    original_driver = (OBSERVER / 'proposed' / REL / 'QwenLayerStageGenerationDriver.swift').read_text()
    marker = '/// Explicit private phase entry.'
    core = 'private func runQwenLayerStageGenerationCore'
    assert driver[:driver.index(marker)] == original_driver[:original_driver.index(core)]
    assert driver[driver.index(core):] == original_driver[original_driver.index(core):]
    checks.append('both ordinary driver wrappers and entire observed core exact frozen observer bytes')
    runtime = (BASE / 'proposed' / REL / 'QwenResidentRuntime.swift').read_text()
    old_runtime = (BASE / 'original' / REL / 'QwenResidentRuntime.swift').read_text()
    for start in ['public var readiness:', '@_spi(Benchmark) public func recordingReadiness',
                  'public func reserve(', '@_spi(Benchmark) public func reserveRecording(',
                  'public func start(', '@_spi(Benchmark) public func startRecording(']:
        assert body(runtime, start, '    ') == body(old_runtime, start, '    '), start
    recording = (BASE / 'proposed' / REL / 'QwenResidentRecording.swift').read_text()
    assert one(recording, 'case serving, recording, phaseObservation', 'case serving, recording') == (BASE / 'original' / REL / 'QwenResidentRecording.swift').read_text()
    checks.append('ordinary readiness/reserve/start wrapper bodies and shared publication helper exact')
    sink = (BASE / 'proposed' / WORKER / 'ResidentEvidenceSink.swift').read_text()
    restored = one(sink, 'deadline: UInt64,\n                 resourceCheck: () throws -> Void = {}) throws', 'deadline: UInt64) throws')
    restored = one(restored, '            try resourceCheck()\n')
    assert restored == (BASE / 'original' / WORKER / 'ResidentEvidenceSink.swift').read_text()
    checks.append('sidecar inverse exact: only borrowed resource check signature/call added')
    main = (BASE / 'proposed' / WORKER / 'WorkerMain.swift').read_text()
    assert main.index('configuration.load.stageCut == 16') < main.index('if argumentsOnly { Darwin.exit(0) }')
    phase_export = (BASE / 'proposed' / REL / 'QwenResidentPhaseExport.swift').read_text()
    assert 'bothRequestStatesRetired' in phase_export and 'force: true' in phase_export
    assert runtime.index('try recorder.seal()') < runtime.index('phaseExport = try .init')
    assert runtime.index('try phasePublish(observed)') < runtime.index('reservation = nil', runtime.index('try phasePublish(observed)'))
    checks.append('phase cut gate precedes pure arguments return; export precedes capacity restoration')
    fixture_sources = {
        'ExactFrame.swift': ('QwenLayerStageSchedule.swift', 'struct QwenLayerStageFrame:'),
        'ExactSessionIdentity.swift': ('QwenLayerStageSession.swift', 'struct QwenLayerStageSessionIdentity:'),
        'ExactPrefillSummary.swift': ('QwenGenerationPrefillPolicy.swift', 'struct QwenGenerationPrefillSummary:'),
    }
    for name, (source, start) in fixture_sources.items():
        actual = (ANCESTOR / 'workspace' / REL / source).read_text()
        assert body(actual, start) in (BASE / 'Tests' / name).read_text(), name
    finish = next(line for line in (ANCESTOR / 'workspace' / REL / 'QwenLayerStageGenerationSchedule.swift').read_text().splitlines() if line.startswith('enum QwenLayerStageGenerationFinishReason:'))
    assert (BASE / 'Tests/ExactFinishReason.swift').read_text() == 'import Foundation\n\n' + finish + '\n'
    assert (BASE / 'Tests/ExactGenerationResult.swift').read_bytes() == (ANCESTOR / 'workspace' / REL / 'QwenLayerStageGenerationResult.swift').read_bytes()
    for name in ['FixtureSupport.swift', 'PhaseCheck.swift', 'ExactFrame.swift']:
        assert (BASE / 'Tests' / name).read_bytes() == (OBSERVER / 'Tests' / name).read_bytes()
    checks.append('five exact native DTOs and original 11-group observer fixture preserved')
    for name in ['owned_process.py', 'build_native.py']:
        assert (BASE / 'Build' / name).read_bytes() == (ANCESTOR / name).read_bytes()
    package = (BASE / 'Build/package_native.py').read_text()
    old_package = (ANCESTOR / 'package_native.py').read_text()
    old_schema = ast.literal_eval(next(node.value for node in ast.walk(ast.parse(old_package))
        if isinstance(node, ast.keyword) and node.arg == 'schema'))
    assert one(package, "schema='qwen27b_resident_phase_native_bundle_v1'", 'schema=' + repr(old_schema)) == old_package
    checks.append('owned unreaped-only helper/build script exact; package schema-only adaptation')
    prepare = (BASE / 'Build/prepare.py').read_text()
    old_prepare = (ANCESTOR / 'prepare.py').read_text()
    restored = one(prepare, 'WORK, CACHE, authority,', 'WORK, CACHE, RELATIVE, authority,')
    restored = one(restored,
        "    for overlay in sorted((DRAFT / 'proposed').rglob('*.swift')):\n        rel = overlay.relative_to(DRAFT / 'proposed')\n        destination = WORK / rel\n        destination.parent.mkdir(parents=True, exist_ok=True)\n        destination.write_bytes(overlay.read_bytes())\n",
        "    overlay = (DRAFT / 'proposed' / RELATIVE).read_bytes()\n    if overlay != (BASE / 'overlay' / RELATIVE).read_bytes():\n        raise RuntimeError('Frozen overlay copy differs')\n    (WORK / RELATIVE).write_bytes(overlay)\n")
    assert restored == old_prepare
    inputs = (BASE / 'Build/build_inputs.py').read_text()
    old_inputs = (ANCESTOR / 'build_inputs.py').read_text()
    for name in ['sha', 'relative', 'snapshot']:
        def function(source):
            tree = ast.parse(source)
            node = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == name)
            return ast.get_source_segment(source, node)
        assert function(inputs) == function(old_inputs)
    checks.append('cache clone/rewrite/retention inverse exact; source hash/walk helpers unchanged')
    python_files = sorted(BASE.rglob('*.py'))
    for path in python_files:
        assert 'workspace' not in path.relative_to(BASE).parts
        ast.parse(path.read_text(), filename=str(path))
    checks.append('Python source syntax parsed without imports or fixture execution')
    immutable = ['QwenResidentControl.swift', 'QwenResidentRequestResources.swift', 'QwenResidentLoading.swift',
        'QwenResidentAdmission.swift', 'QwenLayerStageSession.swift', 'QwenGenerationPrefillPolicy.swift']
    declarations = []
    for name in immutable:
        path = REL / name
        assert not (BASE / 'proposed' / path).exists()
        data = (ANCESTOR / 'workspace' / path).read_bytes()
        assert sha(data) == source_index[str(path)]['sha256']
        declarations.append(dict(path=str(path), sha256=sha(data)))
    checks.append('load/request/Session/control/resource policies unchanged in build ancestry')
    report = dict(schema='resident_phase_native_source_checks_v1', checks=checks, runtime=rows,
        immutableContracts=declarations, expectedPreparedSources=3050, dependencySources=8755,
        pythonFilesParsed=len(python_files), sourceOnly=True, fixturesExecuted=False,
        compilerOrNativeOrModelOrRemoteExecuted=False, workspaceMaterialized=False,
        physicalResourceAdmissionOrClockMeasurementsProved=False)
    (BASE / 'runtime.patch').write_text(''.join(native_patch))
    (BASE / 'integration.patch').write_text(''.join(increment_patch))
    (BASE / 'source-checks.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps(dict(sourceChecks=len(checks), overlayFiles=len(rows), fixtureExecution=False)))

if __name__ == '__main__':
    main()
