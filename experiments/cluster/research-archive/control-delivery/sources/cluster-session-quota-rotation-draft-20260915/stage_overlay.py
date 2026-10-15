"""Apply frozen source only to an existing private copy, never MAIN."""
import argparse
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace', type=Path, required=True)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    if workspace == MAIN or MAIN in workspace.parents or not workspace.is_dir():
        raise ValueError('An existing independent private checkout is required')
    manifest = json.loads((HERE / 'manifest.json').read_text())
    for item in manifest['files']:
        raw = (HERE / item['path']).read_bytes()
        if len(raw) != item['sizeBytes'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise ValueError('Frozen proposal changed: ' + item['path'])
    for item in json.loads((HERE / 'source-pins.json').read_text())['files']:
        raw = (workspace / item['path']).read_bytes()
        if len(raw) != item['sizeBytes'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise ValueError('Private baseline differs: ' + item['path'])
    package = workspace / 'provider-swift/Package.swift'
    if package.read_bytes() != (HERE / 'PrivateChecks/Package.original.swift').read_bytes():
        raise ValueError('Private Package preimage changed')
    mapping = [(path, workspace / path.relative_to(HERE / 'proposed'))
               for path in sorted((HERE / 'proposed').rglob('*.swift'))]
    mapping += [(path, workspace / 'provider-swift/Tests/DistributedRotationOwnerCheck' / path.name)
                for path in sorted((HERE / 'PrivateChecks/RotationOwnerCheck').glob('*.swift'))]
    old_paths = {row['path'] for row in json.loads((HERE / 'source-pins.json').read_text())['files']}
    for source, destination in mapping:
        relative = str(destination.relative_to(workspace))
        if relative not in old_paths and destination.exists():
            raise ValueError('New fixture/runtime destination already exists: ' + relative)
    receipt = []
    for source, destination in mapping:
        destination.parent.mkdir(parents=True, exist_ok=True)
        raw = source.read_bytes()
        destination.write_bytes(raw)
        receipt.append({'path': str(destination.relative_to(workspace)), 'sha256': hashlib.sha256(raw).hexdigest()})
    package.write_bytes((HERE / 'PrivateChecks/Package.proposed.swift').read_bytes())
    (workspace / 'quota-rotation-overlay.json').write_text(json.dumps({'files': receipt,
        'packageSHA256': hashlib.sha256(package.read_bytes()).hexdigest(), 'compiled': False}, indent=2) + '\n')


if __name__ == '__main__':
    main()
