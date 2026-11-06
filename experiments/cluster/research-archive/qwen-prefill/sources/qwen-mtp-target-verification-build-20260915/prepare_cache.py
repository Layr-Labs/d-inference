"""Clone only this task's owned compiler cache; no compiler or model entry."""
from pathlib import Path
import hashlib,json,os,subprocess,time
BASE=Path(__file__).resolve().parent
OLD=BASE.parent/'qwen-resident-mtp-registered-probe-native-build-20260915'
SOURCE=OLD/'workspace/libs/darkbloom-cluster-worker/.build-native-worker'
DESTINATION=BASE/'workspace/libs/darkbloom-cluster-worker/.build-native-worker'

def main():
    if DESTINATION.exists():raise RuntimeError('Refuse existing task cache')
    started=time.monotonic()
    subprocess.run(['/bin/cp','-cR',str(SOURCE),str(DESTINATION)],check=True,timeout=60)
    changed=[]
    for path in DESTINATION.rglob('*'):
        if path.is_symlink() or not path.is_file() or path.suffix not in ('.json','.yaml','.yml'):continue
        if any(x in path.relative_to(DESTINATION).parts for x in ('checkouts','repositories')):continue
        raw=path.read_bytes();updated=raw.replace(str(OLD).encode(),str(BASE).encode())
        if raw!=updated:
            path.write_bytes(updated);changed.append(str(path.relative_to(DESTINATION)))
    cache=DESTINATION/'arm64-apple-macosx/release/ModuleCache'
    held=BASE/'cloned-prior-ModuleCache'
    if cache.exists():cache.rename(held)
    receipt=dict(source=str(SOURCE),destination=str(DESTINATION),method='APFS clone; task-local JSON/YAML absolute paths rewritten; cloned ModuleCache preserved separately',rewritten=changed,moduleCachePreserved=str(held),elapsedSeconds=time.monotonic()-started,compilerExecuted=False,sharedCachesModified=False)
    (BASE/'cache-preparation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(dict(cachePrepared=True,elapsedSeconds=receipt['elapsedSeconds'])))
if __name__=='__main__':main()
