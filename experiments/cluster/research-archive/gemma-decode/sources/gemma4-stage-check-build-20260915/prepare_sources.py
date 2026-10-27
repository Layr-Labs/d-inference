"""Materialize a fresh, exact source closure; never edit MAIN or prior builds."""
from pathlib import Path
import hashlib,json,os,stat,time
BASE=Path(__file__).resolve().parent
OLD=BASE.parent/'qwen-mtp-target-session-build-guarded-20260915'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def relative(value):
    p=Path(value)
    if p.is_absolute() or '..' in p.parts:raise ValueError('Nonrelative source path')
    return p

def checked(path,row):
    raw=path.read_bytes()
    if path.is_symlink() or len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:
        raise RuntimeError('Source pin changed: '+str(path))
    return raw

def main():
    started=time.monotonic();line=json.loads((BASE/'lineage.json').read_bytes())
    authorities=[(OLD/'source-snapshot-1.json',line['baseSourceSnapshotSHA256']),
      (OLD/'dependency-snapshot-1.json',line['baseDependencySnapshotSHA256']),
      (OLD/'native-1/receipt.json',line['baseBuildReceiptSHA256']),
      (BASE/'integration.json',line['integrationSHA256']),
      (BASE/'Inputs/config.json',line['metadataSHA256']),
      (BASE/'foundation-checks.json',line['foundationChecksSHA256'])]
    for path,pin in authorities:
        if sha(path)!=pin:raise RuntimeError('Authority changed: '+str(path))
    for directory,key in [('gemma4-native-layer-stage-draft-20260915','nativeManifestSHA256'),
        ('gemma4-stage-plumbing-draft-20260915','mapperManifestSHA256'),
        ('gemma4-stage-plumbing-runner-correction-20260915','correctedFoundationRunnerManifestSHA256')]:
        root=BASE.parent/directory
        if sha(root/'manifest.json')!=line[key]:raise RuntimeError('Manifest changed')
        for row in json.loads((root/'manifest.json').read_bytes())['members']:
            path=root/relative(row['path']);raw=path.read_bytes()
            if hashlib.sha256(raw).hexdigest()!=row['sha256']:raise RuntimeError('Manifest member changed')
    rows=json.loads((OLD/'source-snapshot-1.json').read_bytes())['members']
    overlays=json.loads((BASE/'integration.json').read_bytes())['files']
    if len(rows)!=3075 or len(overlays)!=17:raise RuntimeError('Wrong source inventory')
    for row in rows:checked(OLD/'workspace'/relative(row['path']),row)
    for row in overlays:
        checked(BASE/'source-overlay'/relative(row['path']),row);old=OLD/'workspace'/relative(row['path'])
        if row['originalSHA256'] is None:
            if old.exists():raise RuntimeError('New source unexpectedly exists')
        elif sha(old)!=row['originalSHA256']:raise RuntimeError('Overlay preimage differs')
    destination=BASE/'workspace';destination.mkdir(mode=0o700)
    for row in rows:
        path=relative(row['path']);source=OLD/'workspace'/path;target=destination/path
        target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as output:output.write(checked(source,row))
        target.chmod(stat.S_IMODE(source.stat().st_mode))
    for row in overlays:
        target=destination/relative(row['path']);target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(checked(BASE/'source-overlay'/relative(row['path']),row));checked(target,row)
    paths={row['path'] for row in overlays}
    for row in rows:
        checked(OLD/'workspace'/relative(row['path']),row)
        if row['path'] not in paths:checked(destination/relative(row['path']),row)
    expected=len(rows)+sum(row['originalSHA256'] is None for row in overlays)
    if expected!=line['expectedSourceFiles']:raise RuntimeError('Wrong assembled count')
    result=dict(baseSourcesCopied=len(rows),overlayFiles=len(overlays),expectedSourceFiles=expected,
        workspace=str(destination),baseSourceSnapshotSHA256=line['baseSourceSnapshotSHA256'],
        integrationSHA256=line['integrationSHA256'],elapsedSeconds=time.monotonic()-started,
        compilerExecuted=False,cacheCloned=False,mainModified=False,modelGPUOrRemoteExecuted=False)
    with (BASE/'source-preparation.json').open('x') as output:json.dump(result,output,indent=2);output.write('\n')
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
