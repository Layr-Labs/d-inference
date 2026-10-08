"""Only small source/manifest/AST checks; never binds or executes a native."""
import ast, hashlib, json
from pathlib import Path

BASE = Path(__file__).resolve().parent
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    original = Path(lineage['originalManifestPath']).parent
    if sha(original / 'manifest.json') != lineage['originalManifestSHA256']: raise ValueError('Original source authority changed')
    original_rows = json.loads((original / 'manifest.json').read_bytes())['files']
    changed = {row['path']: row for row in lineage['changed']}
    rows = json.loads((BASE / 'source-template.json').read_bytes())['files']
    if len(rows) != 78 or [x['path'] for x in rows] != [x['path'] for x in original_rows]:
        raise ValueError('Source template membership differs')
    for old, row in zip(original_rows, rows):
        actual = BASE / 'source' / row['path']
        if actual.is_symlink() or sha(actual) != row['sha256']: raise ValueError('Template member changed')
        if row['path'] in changed:
            if old['sha256'] != changed[row['path']]['beforeSHA256'] or row['sha256'] != changed[row['path']]['afterSHA256']:
                raise ValueError('Changed boundary pin differs')
        elif row['sha256'] != old['sha256']: raise ValueError('Unchanged helper differs')
    python = list(BASE.rglob('*.py'))
    for path in python: ast.parse(path.read_text(), filename=str(path))
    placeholder = json.loads((BASE / 'source/package/native-build-reference.json').read_bytes())
    if placeholder['nativeSHA256'] is not None or placeholder['runtimeExecutionAuthorized']:
        raise ValueError('Source-only placeholder was silently bound')
    print(json.dumps(dict(templateMembers=78, unchangedMembers=73, changedMembers=5,
        pythonAST=len(python), actualBuildBound=False, nativeExecuted=False, remoteExecuted=False), sort_keys=True))

if __name__ == '__main__': main()
