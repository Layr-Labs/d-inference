"""Three sequential bounded native builds and pure argument checks; no GPU mode."""
import json,os,re,sys,time
from build_inputs import BASE,WORKSPACE,SCRATCH,sha
from verify_build_inputs import verify
from check_process import run_owned
PRODUCTS=('WindowedRequestStateCheck','TargetVerificationSessionCheck','TargetVerificationCheck')

def main():
    if len(sys.argv)!=2 or not re.fullmatch(r'[A-Za-z0-9_-]+',sys.argv[1]):raise ValueError('One fresh relative attempt name required')
    out=BASE/sys.argv[1];out.mkdir(mode=0o700)
    receipt=dict(sourceSnapshotSHA256=sha(BASE/'source-snapshot-1.json'),dependencySnapshotSHA256=sha(BASE/'dependency-snapshot-1.json'),
        steps=[],binaries={},nativeFixtureExecuted=False,modelExecuted=False,remoteExecuted=False,status='started')
    print('Gemma composed build runner PID '+str(os.getpid()),flush=True)
    try:
        receipt['before']=verify()
        for product in PRODUCTS:
            verify();name=product.lower()
            args=['swift','build','--package-path',str(WORKSPACE/'libs/darkbloom-cluster-worker'),'--scratch-path',str(SCRATCH),
                '-c','release','--jobs','2','--disable-automatic-resolution','--skip-update','--disable-build-manifest-caching',
                '--triple','arm64-apple-macosx26.2','-Xcc','-target','-Xcc','arm64-apple-macosx26.2',
                '-Xswiftc','-DQWEN_TARGET_TINY_FIXTURE','-Xswiftc','-DCBV2_WINDOW_STATE_FIXTURE','--product',product]
            print('Starting '+product,flush=True)
            receipt['steps'].append(run_owned(args,out,name+'-build',900));verify()
            binary=SCRATCH/'arm64-apple-macosx/release'/product
            receipt['steps'].append(run_owned(['xcrun','vtool','-show-build',str(binary)],out,name+'-version',10))
            version=(out/(name+'-version.stdout')).read_text()
            if version.count('LC_BUILD_VERSION')!=1 or 'platform MACOS' not in version or not any(line.split()==['minos','26.2'] for line in version.splitlines()):raise ValueError('Wrong native build target')
            receipt['steps'].append(run_owned([str(binary),'check-arguments'],out,name+'-arguments',10))
            if json.loads((out/(name+'-arguments.stdout')).read_bytes())!={'argumentsAccepted':True,'nativeExecuted':False}:raise ValueError('Pure argument mode differs')
            receipt['binaries'][product]=dict(path=str(binary),sha256=sha(binary),bytes=binary.stat().st_size)
            print(product+' terminal PASS',flush=True)
        receipt['status']='passed'
    except BaseException as error:
        receipt['status']='failed';receipt['failure']=type(error).__name__+': '+str(error);raise
    finally:
        try:receipt['after']=verify()
        except BaseException as error:
            receipt['status']='failed';receipt['sourceRecheckFailure']=type(error).__name__+': '+str(error)
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    if receipt['status']!='passed':raise ValueError('Post-build source verification failed')
    print('All three composed products PASS; no GPU execution',flush=True)
if __name__=='__main__':main()
