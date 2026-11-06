"""Explicit qualified worker ancestry and exact current-source bridges."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent
WORKSPACE=BASE/'workspace'
SCRATCH=WORKSPACE/'libs/darkbloom-cluster-worker/.build-native-worker'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def relative(value):
    p=Path(value)
    if p.is_absolute() or '..' in p.parts:raise ValueError('Non-relative source path')
    return p

def inputs():
    v=json.loads((BASE/'lineage.json').read_bytes());old=Path(v['base']);probe=Path(v['probe']);scope=Path(v['scope'])
    for row in json.loads((BASE/'helper-lineage.json').read_bytes()):
        if sha(BASE/row['destination'])!=row['sha256']:raise ValueError('Changed copied helper')
    for path,key in [(old/'source-snapshot-1.json','baseSourceSnapshotSHA256'),
        (old/'dependency-snapshot-1.json','baseDependencySnapshotSHA256'),(old/'native-1/receipt.json','basePassedReceiptSHA256'),
        (old/'runtime-bundle-1/bundle.json','baseBundleIdentitySHA256'),(probe/'manifest.json','probeManifestSHA256'),
        (scope/'manifest.json','scopeManifestSHA256')]:
        if sha(path)!=v[key]:raise ValueError('Pinned authority changed: '+str(path))
    if json.loads((old/'native-1/receipt.json').read_bytes()).get('passed') is not True:raise ValueError('Qualified base build is missing')
    for directory in [probe,scope]:
        for row in json.loads((directory/'manifest.json').read_bytes())['members']:
            if sha(directory/relative(row['path']))!=row['sha256']:raise ValueError('Frozen candidate member changed')
    source=json.loads((old/'source-snapshot-1.json').read_bytes())['members']
    integration=json.loads((BASE/'integration.json').read_bytes());overlay=integration['files'];exclude=integration['exclude']
    if len(source)!=3040 or len(overlay)!=45 or len(exclude)!=5:raise ValueError('Wrong reviewed composition inventory')
    by={r['path']:r for r in source}
    for row in overlay:
        relative(row['path'])
        if by.get(row['path'],{}).get('sha256')!=row['beforeSHA256']:raise ValueError('Ancestral preimage differs')
        if sha(Path(row['source']))!=row['afterSHA256']:raise ValueError('Pinned overlay source changed')
    for row in exclude:
        if by.get(row['path'],{}).get('sha256')!=row['beforeSHA256']:raise ValueError('Excluded ancestor changed')
    effective={r['path']:r['sha256'] for r in source}
    effective.update({r['path']:r['afterSHA256'] for r in overlay})
    for row in exclude:effective.pop(row['path'])
    for row in json.loads((BASE/'controls.json').read_bytes())['files']:
        if effective.get(row['path'])!=row['sha256']:raise ValueError('Composed control differs from exact MAIN/frozen source')
    return v,old,source,overlay,exclude

def checked(path,row):
    raw=path.read_bytes()
    if len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:raise ValueError('Changed source: '+str(path))
    if path.is_symlink():raise ValueError('Source copy cannot contain symlinks')
    return raw

def entries(root):
    result=[]
    for path in sorted(root.rglob('*')):
        rel=path.relative_to(root)
        if any(x in ('.git','__pycache__') or x.startswith('.build') for x in rel.parts):continue
        if path.is_file():
            raw=path.read_bytes();row=dict(path=str(rel),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
            if path.is_symlink():row['symlink']=str(path.readlink())
            result.append(row)
    return result
