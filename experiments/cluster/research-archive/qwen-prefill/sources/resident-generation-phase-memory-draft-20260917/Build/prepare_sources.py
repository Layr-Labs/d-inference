"""Exact guarded reuse, not a new compiler-cache clone. Stop on any stale preimage."""
import json, os, shutil, stat, time
from build_inputs import BASE, OLD, DRAFT, WORK, CACHE, authority, relative, sha, snapshot, verify
from owned_process import invoke_controller

def main():
    began=time.monotonic();sources,dependencies=authority()
    if snapshot(WORK)!=sources or snapshot(CACHE/'checkouts')!=dependencies:
        raise RuntimeError('Existing qualified source/dependency closure differs; no current-tree acceptance')
    overlays=json.loads((DRAFT/'source-inputs.json').read_bytes())['overlays']
    for row in overlays:
        p=WORK/relative(row['path']);prior=row['before']
        if prior is None:
            if p.exists() or p.is_symlink():raise RuntimeError('New destination already exists')
        elif p.is_symlink() or not p.is_file() or p.stat().st_size!=prior['bytes'] or sha(p)!=prior['sha256']:
            raise RuntimeError('Exact observer preimage differs: '+row['path'])
    saved=BASE/'retained-phase6495';saved.mkdir(mode=0o700)
    bundle=json.loads((OLD/'runtime-bundle-1/bundle.json').read_bytes())
    binary=CACHE/'arm64-apple-macosx/release/darkbloom-cluster-worker'
    old=next(x for x in bundle['files'] if x['path']=='darkbloom-cluster-worker')
    if binary.is_symlink() or binary.stat().st_size!=old['bytes'] or sha(binary)!=old['sha256']:
        raise RuntimeError('Existing cache binary differs from the qualified phase bundle')
    clone=dict(argv=['/bin/cp','-c',str(binary),str(saved/'darkbloom-cluster-worker')])
    try:
        with (saved/'clone.stdout').open('xb') as stdout,(saved/'clone.stderr').open('xb') as stderr:
            invoke_controller(clone['argv'],stdout,stderr,clone,timeout=30)
    finally:(saved/'clone.json').write_text(json.dumps(clone,indent=2)+'\n')
    if clone.get('exitCode')!=0 or not clone.get('reaped') or not clone.get('groupAbsent') or sha(saved/'darkbloom-cluster-worker')!=old['sha256']:
        raise RuntimeError('Prior cache binary preservation failed')
    # Preserve every replaced source and every absent-destination declaration
    # before the first mutation. Partial attempts are retained, never retried.
    for row in overlays:
        rel=relative(row['path']);p=WORK/rel
        if row['before'] is not None:
            saved_path=saved/'preimages'/rel;saved_path.parent.mkdir(parents=True,exist_ok=True)
            with saved_path.open('xb') as f:f.write(p.read_bytes())
            if sha(saved_path)!=row['before']['sha256']:raise RuntimeError('Preserved preimage differs')
    (saved/'preimage-ledger.json').write_text(json.dumps(overlays,indent=2)+'\n')
    if snapshot(WORK)!=sources or snapshot(CACHE/'checkouts')!=dependencies:
        raise RuntimeError('Source/dependencies changed before first replacement')
    replaced=[]
    for row in overlays:
        rel=relative(row['path']);p=WORK/rel;proposed=DRAFT/'proposed'/rel
        data=proposed.read_bytes()
        if len(data)!=row['after']['bytes'] or sha(proposed)!=row['after']['sha256']:
            raise RuntimeError('Proposed source changed')
        if row['before'] is None:
            with p.open('xb') as f:f.write(data)
        else:
            mode=stat.S_IMODE(p.stat().st_mode);temporary=p.with_name(p.name+'.phase-memory-new')
            with temporary.open('xb') as f:f.write(data)
            temporary.chmod(mode)
            if sha(p)!=row['before']['sha256']:raise RuntimeError('Preimage changed before replacement')
            os.replace(temporary,p)
        replaced.append(row)
        (saved/'overlay-progress.json').write_text(json.dumps(replaced,indent=2)+'\n')
    checked=verify()
    for name,root in [('source-snapshot-1.json',WORK),('dependency-snapshot-1.json',CACHE/'checkouts')]:
        rows=snapshot(root)
        with (BASE/name).open('x') as f:json.dump(dict(root=str(root),memberCount=len(rows),members=rows),f,indent=2);f.write('\n')
    result=dict(**checked,workspaceReused=str(WORK),cacheReused=str(CACHE),compiledCacheCloned=False,
        priorBinarySHA256=old['sha256'],overlays=replaced,elapsedSeconds=time.monotonic()-began,
        compilerOrNativeOrRemoteExecuted=False)
    (BASE/'preparation.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(checked))
if __name__=='__main__':os.umask(0o077);main()
