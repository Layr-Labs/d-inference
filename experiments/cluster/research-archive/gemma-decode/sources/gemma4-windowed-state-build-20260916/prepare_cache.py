"""Clone the successful private cache; no shared MAIN cache or compiler."""
import json,time
from build_inputs import BASE,SCRATCH,inputs
from check_process import run_owned

def main():
    v,old,_,_,_=inputs();prepared=json.loads((BASE/'source-preparation.json').read_bytes())
    if prepared['expectedSourceFiles']!=v['expectedSourceCount']:raise ValueError('Prepare exact sources first')
    if SCRATCH.exists():raise ValueError('Refuse existing task cache')
    out=BASE/'cache-copy';out.mkdir(mode=0o700);start=time.monotonic()
    source=old/'workspace/libs/darkbloom-cluster-worker/.build-native-worker'
    run_owned(['/bin/cp','-cR',str(source),str(SCRATCH)],out,'clone',60)
    changed=[]
    for path in SCRATCH.rglob('*'):
        if path.is_symlink() or not path.is_file() or path.suffix not in ('.json','.yaml','.yml'):continue
        if any(x in path.relative_to(SCRATCH).parts for x in ('checkouts','repositories')):continue
        raw=path.read_bytes();updated=raw.replace(str(old).encode(),str(BASE).encode())
        if raw!=updated:path.write_bytes(updated);changed.append(str(path.relative_to(SCRATCH)))
    cache=SCRATCH/'arm64-apple-macosx/release/ModuleCache';held=BASE/'cloned-prior-ModuleCache'
    if cache.exists():cache.rename(held)
    receipt=dict(source=str(source),destination=str(SCRATCH),method='APFS clone; private JSON/YAML paths rewritten',
        rewritten=changed,priorModuleCache=str(held),elapsedSeconds=time.monotonic()-start,compilerExecuted=False,sharedCacheModified=False)
    with (BASE/'cache-preparation.json').open('x') as f:json.dump(receipt,f,indent=2);f.write('\n')
    print(json.dumps(dict(cachePrepared=True,compilerExecuted=False)))
if __name__=='__main__':main()
