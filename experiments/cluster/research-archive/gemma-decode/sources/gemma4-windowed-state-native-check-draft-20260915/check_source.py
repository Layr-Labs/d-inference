"""Small source/ledger checks only; never launches Swift, MLX, or a model."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    lineage = json.loads((ROOT / 'lineage.json').read_text())
    integration = json.loads((ROOT / 'integration.json').read_text())
    base = Path(integration['base'])
    for package in lineage['packages']:
        root = Path(package['path'])
        assert digest(root / 'manifest.json') == package['manifestSHA256']
        manifest = json.loads((root / 'manifest.json').read_text())
        for row in manifest.get('files', manifest.get('members', [])):
            assert digest(root / row['path']) == row['sha256']
    for row in integration['files']:
        path = base / row['path']
        assert (digest(path) if path.exists() else None) == row['beforeSHA256']
        assert digest(ROOT / 'proposed' / row['path']) == row['afterSHA256']
    composition = json.loads((ROOT / 'core-composition.json').read_text())
    core = (ROOT / 'proposed' / composition['path']).read_text()
    assert digest(ROOT / 'proposed' / composition['path']) == composition['composedSHA256']
    for hunk in reversed(composition['hunks']):
        assert core.count(hunk['after']) == 1
        core = core.replace(hunk['after'], hunk['before'], 1)
    assert core == (base / composition['path']).read_text()
    runtime = ROOT / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    original = Path(lineage['legacySnapshotSource']).read_text().split('\nextension CBv2OwnedRequestState {')[0]
    copied = (runtime / 'WindowedStateLegacySnapshotControl.swift').read_text()
    assert copied == '#if CBV2_WINDOW_STATE_FIXTURE\n' + original.replace(
        'CBv2OwnedStateSnapshot', 'WindowedStateLegacySnapshotControl') + '\n#endif\n'
    for row in lineage['unchangedChecks']:
        assert digest(Path(row['path'])) == row['sha256']
        assert not (ROOT / 'proposed' / Path(row['path']).relative_to(base)).exists()
    for row in lineage['frameworkSourcePins']:
        assert digest(Path(row['path'])) == row['sha256']
    entry = Path(lineage['entrySource']).read_text()
    for before, after in [('TargetVerificationSessionMain', 'WindowedRequestStateMain'),
                          ('TargetVerificationSessionCheck', 'WindowedRequestStateCheck'),
                          ('run-tiny-session-on-gpu', 'run-windowed-state-on-gpu'),
                          ('Tiny Session', 'Windowed state'), ('tiny-session', 'windowed-state'),
                          ('TargetVerificationCheck.arguments', 'WindowedRequestStateCheck.arguments'),
                          ('TargetVerificationCheck.output', 'WindowedRequestStateCheck.output')]:
        entry = entry.replace(before, after)
    assert entry == (ROOT / 'proposed/libs/darkbloom-cluster-worker/Tests/WindowedRequestStateCheck/Main.swift').read_text()
    validation = (runtime / 'CBv2AttentionStateValidation.swift').read_text()
    body = '\n'.join(line for line in validation.splitlines() if not line.lstrip().startswith('//'))
    assert all(token not in body for token in ['.snapshot(', '.asData(', 'eval(', '.innerState('])
    for path in runtime.glob('Windowed*.swift'):
        assert path.read_text().startswith('#if CBV2_WINDOW_STATE_FIXTURE\n')
        assert ': CBv2SequenceKV' not in path.read_text()
    assert sum([1, 1, 1, 1, 1, 7, 4, 5]) == 21
    exact = 32 * 1 * 32 * 2 * 2 + 4 * 2 * 64 * 4 * 2
    conservative = 32 * 1 * 32 * 4 * 2 + 4 * 2 * 64 * 4 * 2
    temporary = (4 + 4 - 1 + 7) * 2 * 64 * 4 * 2
    assert (exact, conservative, temporary) == (8192, 12288, 14336)
    assert max(0, 21 - 4) == 17
    return {'passed': True, 'proposedSwiftFiles': len(integration['files']),
            'exactComposedCoreInverse': True, 'legacyCaptureBodyExact': True,
            'existingEntryLifecycleExact': True,
            'unchangedExistingChecks': len(lineage['unchangedChecks']),
            'logicalKVBytes': exact, 'backendReservationBytes': conservative,
            'retainedWindowTemporaryBoundBytes': temporary, 'finalSyntheticFrontier': 21,
            'swiftCompilerExecuted': False, 'nativeExecuted': False, 'fixtureResultsClaimed': False}


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
