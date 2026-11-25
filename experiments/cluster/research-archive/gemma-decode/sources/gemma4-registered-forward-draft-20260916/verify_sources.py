"""Small source/manifest checks only; never compiles or reads model payloads."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def matches(path, size, expected):
    raw = path.read_bytes()
    if len(raw) != size or hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('Source changed: ' + str(path))


def main():
    manifest = json.loads((BASE / 'manifest.json').read_text())
    for row in manifest['members']:
        matches(BASE / row['path'], row['bytes'], row['sha256'])
    controls = json.loads((BASE / 'source-controls.json').read_text())
    categories = ['foundationInputs', 'nativeSelectedAPIControls', 'upstreamAuthorityMetadata',
                  'nativeStageSources', 'mainQwenControls']
    for category in categories:
        for row in controls[category]:
            matches(Path(row['path']), row['sizeBytes'], row['sha256'])
    integration = json.loads((BASE / 'integration.json').read_text())
    for root in [Path('/Users/developer/DarkbloomDev/d-inference'), Path(integration['nativeSourceBase'])]:
        for row in integration['nativeStagePrerequisites'] + integration['newRuntime']:
            target = root / row['path']
            actual = hashlib.sha256(target.read_bytes()).hexdigest() if target.exists() else None
            if target.is_symlink() or actual != row['beforeSHA256']:
                raise ValueError('Integration preimage changed: ' + str(target))
    for path in [BASE / 'Tests/run.py', Path(__file__)]:
        ast.parse(path.read_text(), filename=str(path))
    print(json.dumps({'sourceChecksPassed': True, 'members': len(manifest['members']),
        'nativeCompiled': False, 'foundationExecuted': False, 'payloadRead': False}))


if __name__ == '__main__':
    main()
