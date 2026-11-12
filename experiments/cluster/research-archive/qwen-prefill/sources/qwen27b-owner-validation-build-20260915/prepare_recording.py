"""Clone the validated 27B source/cache and apply only the frozen recording wrapper."""
from pathlib import Path
import hashlib, importlib.util, json, os, shutil, subprocess, time
ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent
OLD=BASE/'qwen27b-resident-native-build-20260915'
FROZEN=BASE/'qwen27b-owner-qualification-draft-20260915'
WORK=ROOT/'workspace'
spec=importlib.util.spec_from_file_location('prior_preparation',OLD/'prepare.py')
prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(name,value):(ROOT/name).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
def main():
    assert sha(FROZEN/'manifest.json')=='211c1ec3b03367e4b5b71f8a4c69233bda78e4c4f50806f50ad8fff49a06ee17'
    for row in json.loads((FROZEN/'manifest.json').read_text())['members']:
        assert sha(FROZEN/row['path'])==row['sha256'],row['path']
    source=OLD/'workspace'; before=prior.snapshot(source)
    WORK.mkdir(mode=0o700,exist_ok=False)
    for package in prior.PACKAGES:
        shutil.copytree(source/'libs'/package,WORK/'libs'/package,symlinks=True,ignore=prior.ignore)
    assert before==prior.snapshot(source)==prior.snapshot(WORK)
    write('source-preimages.json',dict(root=str(source),members=before))
    for argv in (['git','apply','--check'],['git','apply']):
        result=subprocess.run(argv+['--whitespace=error',str(FROZEN/'recording-worker.patch')],cwd=WORK,capture_output=True,check=True)
        assert not result.stdout and not result.stderr
    for file in (FROZEN/'recording-worker').glob('*.swift'):
        assert sha(file)==sha(WORK/'libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker'/file.name)
    rows=prior.snapshot(WORK)
    write('source-snapshot.json',dict(root=str(WORK),memberCount=len(rows),members=rows))
    cache_source=source/'libs/darkbloom-cluster-worker/.build-native-worker'
    cache=WORK/'libs/darkbloom-cluster-worker/.build-native-worker'
    began=time.monotonic();subprocess.run(['/bin/cp','-cR',str(cache_source),str(cache)],check=True)
    rewrites=[]
    for current,dirs,names in os.walk(cache):
        dirs[:]=[x for x in dirs if x not in {'checkouts','repositories','prebuilts','artifacts','ModuleCache'}]
        for name in names:
            path=Path(current)/name
            if path.is_symlink() or path.suffix not in {'.json','.yaml'}:continue
            raw=path.read_bytes();changed=raw.replace(str(source).encode(),str(WORK).encode())
            if changed!=raw:
                rewrites.append(dict(path=str(path.relative_to(cache)),beforeSHA256=hashlib.sha256(raw).hexdigest(),afterSHA256=hashlib.sha256(changed).hexdigest()))
                path.write_bytes(changed)
    moved=[]
    for path in list(cache.rglob('ModuleCache')):
        if not path.is_dir() or 'checkouts' in path.relative_to(cache).parts:continue
        target=ROOT/('cloned-worker-'+'-'.join(path.relative_to(cache).parts));path.rename(target)
        moved.append(dict(source=str(path),retainedAt=str(target)))
    write('cache-preparation.json',dict(source=str(cache_source),destination=str(cache),method='owned APFS clone',seconds=time.monotonic()-began,generatedPathRewrites=rewrites,retainedModuleCaches=moved,sourceCacheMutated=False))
    deps=prior.snapshot(cache/'checkouts')
    assert deps==prior.snapshot(cache_source/'checkouts')
    write('dependency-source-snapshot.json',dict(root=str(cache/'checkouts'),members=deps,memberCount=len(deps)))
    assert before==prior.snapshot(source) and rows==prior.snapshot(WORK)
    write('preparation.json',dict(frozenManifestSHA256=sha(FROZEN/'manifest.json'),sourceSnapshotSHA256=sha(ROOT/'source-snapshot.json'),dependencySnapshotSHA256=sha(ROOT/'dependency-source-snapshot.json'),recordingWorkerFiles=3,sourceMembers=len(rows),dependencyMembers=len(deps),compilerInvoked=False,modelPayloadRead=False,remoteOperations=False))
    print(json.dumps(dict(prepared=True,sources=len(rows),dependencies=len(deps))),flush=True)
if __name__=='__main__':main()
