"""Root-granted controller-only relink plus exact Foundation host-budget metadata."""
from pathlib import Path
import hashlib,json,os,shutil,sys,time
from owned_process import invoke_controller
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent.parent
OLD=ROOT/'cluster-owner-diagnostic-drain-draft-20260915'
PHASE=ROOT/'resident-generation-phase-native-draft-20260916'
MODULES=OLD/'local-build-1/artifacts'
LIBS=OLD/'local-bundle'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
    for row in json.loads((BASE.parent/'manifest.json').read_bytes())['members']:
        p=BASE.parent/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    for row in json.loads((BASE/'source-inputs.json').read_bytes()):
        p=Path(row['path']);assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    manifest=json.loads((LIBS/'bundle.json').read_bytes())
    assert sha(LIBS/'bundle.json')=='e650ebc820b42e7b57cf105b81b60c01320d22f40cfe1e1de70c52a13440fdaa'
    for row in manifest['entries']:
        p=LIBS/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    return manifest

def main():
    attempt,=sys.argv[1:];assert attempt.isdecimal() and 1<=int(attempt)<=99
    original=verify();out=BASE/('build-'+attempt);out.mkdir(mode=0o700)
    pins=[dict(path=str(p),bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(BASE.glob('*.swift'))]
    pins += [dict(path=str(BASE/n),bytes=(BASE/n).stat().st_size,sha256=sha(BASE/n)) for n in ['build.py','source-inputs.json','owned_process.py']]
    (out/'source-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    rt=PHASE/'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    sources=[rt/('QwenGenerationPhase'+n+'.swift') for n in ['Observation','Budget','HostAllocation']]
    sources += [PHASE/'Build/workspace/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/ClusterRuntimeError.swift',BASE/'PhaseBudgetMetadata.swift']
    swift=['/usr/bin/xcrun','swiftc','-swift-version','6','-j','2','-warnings-as-errors','-target','arm64-apple-macos14.0','-parse-as-library']
    links=['-I',str(MODULES),'-L',str(LIBS)]
    for name in ['Protocol','Bootstrap','Process','Remote']:links += ['-lDarkbloomCluster'+name]
    links += ['-Xlinker','-rpath','-Xlinker','@executable_path']
    bundle=out/'bundle';bundle.mkdir(mode=0o700)
    commands=[('budget-compile',swift+list(map(str,sources))+['-o',str(out/'phase-budget')],90),
        ('budget-run',[str(out/'phase-budget')],30),
        ('controller-relink',swift+links+[str(BASE/n) for n in ['Controller.swift','QualificationInput.swift','OwnerTransportObservation.swift']]+['-o',str(bundle/'owner-controller')],90),
        ('controller-linkage',['/usr/bin/otool','-L',str(bundle/'owner-controller')],10),
        ('controller-platform',['/usr/bin/vtool','-show-build',str(bundle/'owner-controller')],10)]
    result=dict(passed=False,steps=[],nativeModelOrRemoteExecuted=False,compilerJobsMaximum=2)
    began=time.monotonic()
    try:
        for name,argv,seconds in commands:
            step=dict(name=name,argv=argv);result['steps'].append(step)
            with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
                invoke_controller(argv,stdout,stderr,step,timeout=seconds)
            assert step.get('exitCode')==0 and step.get('reaped') and step.get('groupAbsent')
            assert (out/(name+'.stderr')).stat().st_size==0
        budget=json.loads((out/'budget-run.stdout').read_bytes());assert budget['maximumEvents']==288
        verify()
        assert all(Path(x['path']).stat().st_size==x['bytes'] and sha(Path(x['path']))==x['sha256'] for x in pins)
        for row in original['entries']:
            if row['path'].endswith('.dylib'):
                shutil.copyfile(LIBS/row['path'],bundle/row['path'])
                assert sha(bundle/row['path'])==row['sha256']
        members=[dict(path=p.name,bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(bundle.iterdir())]
        (bundle/'bundle.json').write_text(json.dumps(dict(schema='resident_phase_controller_bundle_v1',files=members,
            originalBundleSHA256=sha(LIBS/'bundle.json'),sourcePinsSHA256=sha(out/'source-pins.json'),nativeOrRemoteOwnerChanged=False),indent=2)+'\n')
        result.update(passed=True,bundleSHA256=sha(bundle/'bundle.json'),hostBudgetSHA256=sha(out/'budget-run.stdout'),sourcePinsUnchanged=True)
    finally:
        result['elapsedSeconds']=time.monotonic()-began
        (out/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
if __name__=='__main__':
    os.umask(0o077);main()
