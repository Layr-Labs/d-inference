"""Granted-slot native typecheck/build only; never selects the GPU fixture mode."""
from pathlib import Path
import hashlib,json,os,signal,subprocess,sys,time
from verify_build_inputs import verify
BASE=Path(__file__).resolve().parent
PACKAGE=BASE/'workspace/libs/darkbloom-cluster-worker'
SCRATCH=PACKAGE/'.build-native-worker'
PRODUCT='TargetVerificationSessionCheck'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    out=BASE/sys.argv[1];out.mkdir(mode=0o700)
    receipt=dict(sourceSnapshotSHA256=sha(BASE/'source-snapshot-1.json'),dependencySnapshotSHA256=sha(BASE/'dependency-snapshot-1.json'),before=verify(),steps=[],nativeFixtureExecuted=False,modelExecuted=False,remoteExecuted=False)
    def run(name,args,limit):
        start=time.monotonic();failure=None
        with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
            child=subprocess.Popen(args,stdout=stdout,stderr=stderr,start_new_session=True)
            print(name+' pid '+str(child.pid),flush=True)
            try:code=child.wait(timeout=limit)
            except BaseException as error:
                failure=type(error).__name__+': '+str(error)
                if child.returncode is None:
                    try:os.killpg(child.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                child.wait();code=child.returncode
        receipt['steps'].append(dict(name=name,argv=args,pid=child.pid,exitCode=code,elapsedSeconds=time.monotonic()-start,failure=failure,stdoutSHA256=sha(out/(name+'.stdout')),stderrSHA256=sha(out/(name+'.stderr'))))
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
        print(name+' terminal '+str(code),flush=True)
        if code or failure:raise SystemExit(code if code else 1)
    args=['swift','build','--package-path',str(PACKAGE),'--scratch-path',str(SCRATCH),'-c','release','--jobs','2','--disable-automatic-resolution','--skip-update','--disable-build-manifest-caching','--triple','arm64-apple-macosx26.2','-Xcc','-target','-Xcc','arm64-apple-macosx26.2','-Xswiftc','-DQWEN_TARGET_TINY_FIXTURE','--product',PRODUCT]
    run('native-build',args,900)
    binary=SCRATCH/'arm64-apple-macosx/release'/PRODUCT
    run('build-version',['xcrun','vtool','-show-build',str(binary)],10)
    version=(out/'build-version.stdout').read_text()
    if version.count('LC_BUILD_VERSION')!=1 or 'platform MACOS' not in version or not any(line.split()==['minos','26.2'] for line in version.splitlines()):raise RuntimeError('Wrong native build target')
    run('arguments',[str(binary),'check-arguments'],10)
    if json.loads((out/'arguments.stdout').read_bytes())!={'argumentsAccepted':True,'nativeExecuted':False}:raise RuntimeError('Pure arguments mode differs')
    receipt.update(status='passed',after=verify(),binarySHA256=sha(binary))
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    print('native preparation PASS '+receipt['binarySHA256'],flush=True)
if __name__=='__main__':main()
