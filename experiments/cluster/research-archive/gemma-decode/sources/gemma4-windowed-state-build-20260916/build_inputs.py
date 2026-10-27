"""Pinned source authority shared by the bounded preparation wrappers."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent
WORKSPACE=BASE/'workspace'
SCRATCH=WORKSPACE/'libs/darkbloom-cluster-worker/.build-native-worker'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def relative(value):
    path=Path(value)
    if path.is_absolute() or '..' in path.parts:raise ValueError('Non-relative source path')
    return path

def inputs():
    v=json.loads((BASE/'lineage.json').read_bytes());old=Path(v['base']);draft=Path(v['draft'])
    for helper in json.loads((BASE/'helper-lineage.json').read_bytes()):
        if sha(BASE/helper['destination'])!=helper['sha256']:raise ValueError('Changed copied helper: '+helper['destination'])
    for path,key in [(old/'source-snapshot-1.json','baseSourceSnapshotSHA256'),
        (old/'dependency-snapshot-1.json','baseDependencySnapshotSHA256'),
        (old/'native-1/receipt.json','basePassedReceiptSHA256'),(draft/'manifest.json','draftManifestSHA256'),
        (draft/'integration.json','draftIntegrationSHA256'),(BASE/'integration.json','draftIntegrationSHA256'),
        (draft/'runtime.patch','runtimePatchSHA256'),(BASE/'runtime.patch','runtimePatchSHA256')]:
        if sha(path)!=v[key]:raise ValueError('Pinned authority changed: '+str(path))
    if json.loads((old/'native-1/receipt.json').read_bytes())['status']!='passed':raise ValueError('Base is not qualified')
    source=json.loads((old/'source-snapshot-1.json').read_bytes())['members']
    overlay=json.loads((BASE/'integration.json').read_bytes())['files']
    if len(source)!=v['baseSourceCount'] or len(overlay)!=28:raise ValueError('Wrong source inventory')
    return v,old,draft,source,overlay

def checked(path,row):
    raw=path.read_bytes()
    if len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:raise ValueError('Changed source: '+str(path))
    if path.is_symlink():raise ValueError('Base source copy cannot contain symlinks')
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
