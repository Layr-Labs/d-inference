"""Read-only pins/inverse checks. Does not build, run fixtures or touch a workspace."""
from pathlib import Path
import hashlib
import json

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manifest = json.loads((BASE / 'manifest.json').read_bytes())
    for row in manifest['members']:
        path = BASE / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise RuntimeError('Frozen member changed: ' + row['path'])
    inputs = json.loads((BASE / 'source-inputs.json').read_bytes())
    for row in inputs['authorities']:
        path = Path(row['path'])
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise RuntimeError('Source authority changed: ' + row['path'])
    edits = json.loads((BASE / 'edits.json').read_bytes())
    for row in inputs['preimages']:
        relative = row['relativePath']
        original = BASE / 'original' / relative
        proposed = BASE / 'proposed' / relative
        if sha(original) != row['sha256']:
            raise RuntimeError('Preimage differs: ' + relative)
        text = proposed.read_text()
        for edit in reversed([value for value in edits if value['path'] == relative]):
            if text.count(edit['after']) != 1:
                raise RuntimeError('Inverse is not unique: ' + relative)
            text = text.replace(edit['after'], edit['before'], 1)
        if text.encode() != original.read_bytes():
            raise RuntimeError('Inverse differs: ' + relative)
    runtime = BASE / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    original = BASE / 'original/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    for old in original.glob('*.swift'):
        new = runtime / old.name
        for spelling in ['eval(', '.synchronize(', 'Memory.clearCache(', 'Memory.cacheLimit']:
            if old.read_text().count(spelling) != new.read_text().count(spelling):
                raise RuntimeError('Evaluation/cache operation count changed: ' + old.name)
    for name in ['QwenConvolutionCompaction.swift', 'QwenConvolutionCompactionRows.swift']:
        text = (runtime / name).read_text()
        for spelling in ['eval(', '.synchronize(', 'asArray(', 'asData(', 'FileHandle', 'Memory.clearCache(']:
            if spelling in text:
                raise RuntimeError('Unexpected operation in compaction source: ' + spelling)
    methods = [line.strip().split('(')[0].removeprefix('func ')
               for line in (BASE / 'Tests/ConvolutionCompactionTests.swift').read_text().splitlines()
               if line.strip().startswith('func test')]
    if methods != inputs['testMethods']:
        raise RuntimeError('Expected semantic tests changed')
    print(json.dumps({'sourceOnly': True, 'preimages': len(inputs['preimages']),
                      'runtimeOverlays': 7, 'testMethods': methods,
                      'compilerOrFixtureExecuted': False}, sort_keys=True))


if __name__ == '__main__':
    main()
