"""Small source/evidence pin and syntax checks only; never reads native weights."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    value = json.loads((BASE / 'lineage.json').read_bytes())
    for row in value['pins']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Pinned source/evidence changed: ' + str(path))
    old = Path(value['originalSource'])
    original = json.loads((old / 'manifest.json').read_bytes())['files']
    changed = set(value['changedSourceMembers'])
    for row in original:
        if row['path'] in changed: continue
        path = BASE / 'source' / row['path']
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Inherited source changed: ' + row['path'])
    for manifest, key, root in [(BASE / 'source/manifest.json', 'files', BASE / 'source'),
                                (BASE / 'manifest.json', 'members', BASE)]:
        if manifest.exists():
            for row in json.loads(manifest.read_bytes())[key]:
                path = root / row['path']
                if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
                    raise ValueError('Frozen successor member changed: ' + str(path))
    count = 0
    for directory in [BASE / 'source', BASE / 'Tests']:
        for path in directory.rglob('*.py'):
            ast.parse(path.read_text(), filename=str(path)); count += 1
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text(), filename=str(path)); count += 1
    return dict(pythonAST=count, inheritedSourceMembers=len(original),
                changedSourceMembers=len(changed), externalSmallPins=len(value['pins']),
                testsExecuted=False, nativeOrModelExecuted=False, remoteExecuted=False)


if __name__ == '__main__': print(json.dumps(check(), sort_keys=True))
