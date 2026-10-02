#!/usr/bin/env python3
"""Source-only closure/inverse verification; no compiler or model invocation."""
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def pin(path):
    raw = path.read_bytes()
    return len(raw), hashlib.sha256(raw).hexdigest()

def main():
    spec = json.loads((ROOT / 'composition.json').read_text())
    base = spec['base']
    assert pin(Path(base['path'])) == (base['bytes'], base['sha256'])
    original = json.loads(Path(base['path']).read_text())
    files = {x['path']: x for x in original['files']}
    assert len(files) == len(original['files']) == 116
    patch = []
    assert len(spec['files']) == 12
    for item in spec['files']:
        assert files[item['path']] == item['before']
        before = ROOT / 'preimages' / Path(item['path']).name
        after = ROOT / item['source']
        assert pin(before) == (item['before']['bytes'], item['before']['sha256'])
        assert pin(after) == (item['bytes'], item['sha256'])
        patch.extend(difflib.unified_diff(before.read_text().splitlines(True), after.read_text().splitlines(True),
            fromfile='a/' + item['path'], tofile='b/' + item['path']))
    assert ''.join(patch) == (ROOT / 'runtime.patch').read_text()
    for item in json.loads((ROOT / 'Tests/commands.json').read_text())['dependencyPins']:
        assert pin(Path(item['path'])) == (item['bytes'], item['sha256'])
    manifest = ROOT / 'source-inputs.json'
    if manifest.exists():
        for item in json.loads(manifest.read_text())['members']:
            assert pin(ROOT / item['path']) == (item['bytes'], item['sha256'])
    print('PASS source only: 12 exact preimages/overlays and patch reproduction; no compilation or runtime qualification')

if __name__ == '__main__':
    main()
