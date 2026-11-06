#!/usr/bin/env python3
"""Copy only pinned sources from the completed private MTP build; no compiler."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(base):
    receipt = base.parent / 'records/build-source-snapshot.json'
    assert digest(receipt) == 'b5aa892521d4b01142aba0e5e4e1b2c9541e76987c5cdecea39f1fa4b98d4095'
    original = json.loads(receipt.read_text())['members']
    destination = ROOT / 'workspace'
    destination.mkdir(mode=0o700, exist_ok=False)
    for row in original:
        source = base / row['path']
        assert digest(source) == row['sha256'], row['path']
        target = destination / row['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target.symlink_to(source.readlink())
        else:
            shutil.copy2(source, target)
    for row in json.loads((ROOT / 'integration.json').read_text())['files']:
        source = ROOT / 'proposed' / row['path']
        assert digest(source) == row['sha256']
        target = destination / row['path']
        if row['baseSHA256'] is not None:
            assert digest(target) == row['baseSHA256']
        else:
            assert not target.exists()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    members = []
    for path in sorted(destination.rglob('*')):
        if path.is_file():
            members.append({'path': str(path.relative_to(destination)),
                            'bytes': path.stat().st_size, 'sha256': digest(path)})
    (ROOT / 'build-source-snapshot.json').write_text(json.dumps({'members': members}, indent=2) + '\n')
    print(len(members), 'pinned source inputs copied; no cache/compiler/native execution')


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve())
