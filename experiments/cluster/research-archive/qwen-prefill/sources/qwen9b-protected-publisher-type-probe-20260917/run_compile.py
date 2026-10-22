import hashlib,json,os,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'qwen9b-protected-evidence-thunk-build-20260917'
sys.path.insert(0,str(BASE))
from check_process import run_owned

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
pins={p.name:sha(p) for p in ROOT.glob('*.swift')}
OUT=ROOT/'compile-1';OUT.mkdir(mode=0o700)
started=time.monotonic();results=[]
try:
    for name in ['Borrowed','EscapingPublisher','ScopedPublisher']:
        source=ROOT/(name+'.swift')
        command=['xcrun','swiftc','-j','2','-swift-version','6','-warnings-as-errors','-target','arm64-apple-macosx26.2','-parse-as-library','-module-cache-path',str(ROOT/'module-cache'),'-O','-emit-object',str(source),'-o',str(OUT/(name+'.o'))]
        error=None
        try:run_owned(command,OUT,name,20)
        except ValueError as e:error=str(e)
        row=json.loads((OUT/(name+'.json')).read_text())
        stderr=(OUT/(name+'.stderr')).read_text()
        assert row['reaped'] and row['groupAbsent'] and not row.get('timedOut') and not row.get('killedOwnedGroup')
        if name=='Borrowed':
            assert row['exitCode']==1 and 'passing a closure which captures a non-escaping function parameter' in stderr and "'check'" in stderr
        else:assert row['exitCode']==0 and not stderr and error is None
        results.append(dict(name=name,exitCode=row['exitCode'],elapsedSeconds=row['elapsedSeconds'],expectedResult=True))
finally:
    assert pins=={p.name:sha(p) for p in ROOT.glob('*.swift')}
    (OUT/'receipt.json').write_text(json.dumps(dict(sourcePins=pins,results=results,elapsedSeconds=time.monotonic()-started,compiledOnly=True,executablesRun=False,fullRuntimeBuilt=False),indent=2,sort_keys=True)+'\n')
print(json.dumps(results))
