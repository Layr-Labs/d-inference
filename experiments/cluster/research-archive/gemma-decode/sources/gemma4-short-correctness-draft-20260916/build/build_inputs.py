"""Exact small authorities now; full ancestry validation only during granted preparation."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent
DRAFT=BASE.parent
WORKSPACE=BASE/'workspace'
SCRATCH=WORKSPACE/'libs/darkbloom-cluster-worker/.build-native-worker'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def relative(value):
    path=Path(value)
    if path.is_absolute() or '..' in path.parts:raise ValueError('Non-relative source path')
    return path
def checked(path,row):
    if path.is_symlink():raise ValueError('Source copy cannot contain symlinks')
    raw=path.read_bytes()
    if len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:raise ValueError('Changed source: '+str(path))
    return raw
def inputs():
    v=json.loads((BASE/'lineage.json').read_bytes());old=Path(v['base'])
    for row in json.loads((DRAFT/'source-controls.json').read_bytes())['files']:
        checked(Path(row['path']),row)
    for row in json.loads((DRAFT/'manifest.json').read_bytes())['members']:
        checked(DRAFT/relative(row['path']),row)
    source=json.loads((old/'source-snapshot-1.json').read_bytes())['members']
    overlay=json.loads((BASE/'integration.json').read_bytes())['files']
    if len(source)!=v['baseSourceCount'] or len(overlay)!=v['overlayCount']:raise ValueError('Wrong source inventory')
    if json.loads((old/'native-1/receipt.json').read_bytes())['status']!='passed':raise ValueError('Base is not qualified')
    for row in overlay:
        if sha(Path(row['sourceFile']))!=row['afterSHA256']:raise ValueError('Overlay source changed')
    return v,old,DRAFT,source,overlay
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
