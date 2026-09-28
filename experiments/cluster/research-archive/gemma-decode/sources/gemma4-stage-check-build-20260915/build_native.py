"""Build only the Gemma stage fixture, then execute value-only metadata checks."""
from pathlib import Path
import contextlib,hashlib,io,json,os,re,sys,time
from owned_process import invoke_controller
from verify_build_inputs import verify
BASE=Path(__file__).resolve().parent
PACKAGE=BASE/'workspace/libs/darkbloom-cluster-worker'
SCRATCH=PACKAGE/'.build-native-worker'
PRODUCT='Gemma4StageConstructorCheck'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    if len(sys.argv)!=2 or re.fullmatch(r'native-[1-9][0-9]*',sys.argv[1]) is None:raise ValueError('Expected new native-N attempt')
    out=BASE/sys.argv[1];out.mkdir(mode=0o700)
    line=json.loads((BASE/'lineage.json').read_bytes())
    if sha(BASE/'Inputs/config.json')!=line['metadataSHA256']:raise RuntimeError('Metadata changed')
    receipt=dict(sourceSnapshotSHA256=sha(BASE/'source-snapshot-1.json'),dependencySnapshotSHA256=sha(BASE/'dependency-snapshot-1.json'),before=verify(),steps=[],nativeModelConstructed=False,payloadRead=False,remoteExecuted=False)
    def save():
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    def run(name,args,limit):
        step=dict(name=name,argv=args);start=time.monotonic();observation=io.StringIO();failure=None
        try:
            with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
                with contextlib.redirect_stdout(observation):invoke_controller(args,stdout,stderr,step,timeout=limit)
        except BaseException as error:failure=error
        finally:
            step.update(elapsedSeconds=time.monotonic()-start,launchObservation=observation.getvalue(),stdoutSHA256=sha(out/(name+'.stdout')),stderrSHA256=sha(out/(name+'.stderr')))
            receipt['steps'].append(step);save()
        print(name+' terminal '+str(step.get('exitCode'))+' pid '+str(step.get('pid')),flush=True)
        if failure is not None:raise failure
        if step.get('exitCode')!=0 or not step.get('reaped') or not step.get('groupAbsent'):raise RuntimeError(name+' failed or child cleanup unproven')
    try:
        print('Gemma build runner pid '+str(os.getpid()),flush=True)
        run('native-build',['swift','build','--package-path',str(PACKAGE),'--scratch-path',str(SCRATCH),'-c','release','--jobs','2','--disable-automatic-resolution','--skip-update','--disable-build-manifest-caching','--triple','arm64-apple-macosx26.2','-Xcc','-target','-Xcc','arm64-apple-macosx26.2','-Xswiftc','-enable-testing','--product',PRODUCT],900)
        binary=SCRATCH/'arm64-apple-macosx/release'/PRODUCT
        run('build-version',['xcrun','vtool','-show-build',str(binary)],10)
        version=(out/'build-version.stdout').read_text()
        if version.count('LC_BUILD_VERSION')!=1 or 'platform MACOS' not in version or not any(x.split()==['minos','26.2'] for x in version.splitlines()):raise RuntimeError('Wrong native build target')
        run('metadata',[str(binary),'check-metadata',str(BASE/'Inputs/config.json')],20)
        expected=dict(passed=True,valueOnlyGroups=7,actualArtifactCuts=29,nativeModelConstructed=False,payloadRead=False)
        if json.loads((out/'metadata.stdout').read_bytes())!=expected:raise RuntimeError('Metadata result differs')
        if (out/'metadata.stderr').stat().st_size:raise RuntimeError('Metadata stderr not empty')
        if sha(BASE/'Inputs/config.json')!=line['metadataSHA256']:raise RuntimeError('Metadata changed')
        receipt.update(status='passed',binarySHA256=sha(binary),checks=expected)
    except BaseException as error:
        receipt.update(status='failed',failure=type(error).__name__+': '+str(error));raise
    finally:receipt['after']=verify();save()
    print('Gemma stage native compile + metadata PASS '+receipt['binarySHA256'],flush=True)
if __name__=='__main__':os.umask(0o077);main()
