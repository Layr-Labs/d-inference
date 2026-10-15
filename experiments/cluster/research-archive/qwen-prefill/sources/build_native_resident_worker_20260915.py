from pathlib import Path
import datetime,hashlib,json,os,shutil,signal,subprocess,time

research=Path(__file__).resolve().parent
source=research/'resident-native-worker-policy-build-20260915/workspace/libs/darkbloom-cluster'
tested=research/'resident-native-worker-policy-build-20260915/tests-2/execution.json'
receipt=json.loads(tested.read_bytes())
assert receipt['exitCode']==0 and receipt['sourcePinsUnchanged'] and len(receipt['sourcePinsBefore'])==96
root=research/'resident-native-worker-rdma-build-20260915'
root.mkdir()
package=root/'workspace/libs/darkbloom-cluster';package.mkdir(parents=True)
for row in receipt['sourcePinsBefore']:
    src=source/row['path'];raw=src.read_bytes()
    assert hashlib.sha256(raw).hexdigest()==row['sha256']
    dst=package/row['path'];dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
shutil.copy2(source/'Package.resolved',package/'Package.resolved')
dependencies=[]
for name in ['mlx-swift','mlx-swift-lm']:
    dep=research.parent/'d-inference/libs'/name
    p=subprocess.run(['git','status','--porcelain'],cwd=dep,capture_output=True,text=True,check=True,timeout=10)
    assert not p.stdout and not p.stderr
    commit=subprocess.run(['git','rev-parse','HEAD'],cwd=dep,capture_output=True,text=True,check=True,timeout=10).stdout.strip()
    (package.parent/name).symlink_to(dep,target_is_directory=True)
    dependencies.append({'name':name,'path':str(dep),'commit':commit,'cleanBeforeBuild':True})
script=research/'resident-native-worker-draft-20260915/build-native-worker.sh'
metallib=research/'resident-cache-off-package-20260915/bundle/mlx.metallib'
metalpin='2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
assert hashlib.sha256(metallib.read_bytes()).hexdigest()==metalpin
argv=['/bin/bash',str(script),str(package),str(metallib),metalpin]
record={'atUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'argv':argv,
    'testedSourceReceiptSHA256':hashlib.sha256(tested.read_bytes()).hexdigest(),
    'sourcePins':receipt['sourcePinsBefore'],'dependencies':dependencies,
    'buildScriptSHA256':hashlib.sha256(script.read_bytes()).hexdigest(),
    'matchedMetallibSHA256':metalpin,'sourceResolvedSHA256':hashlib.sha256((package/'Package.resolved').read_bytes()).hexdigest(),
    'modelOrGPUExecution':False}
(root/'input.json').write_text(json.dumps(record,indent=2)+'\n')
start=time.monotonic()
with (root/'build.stdout').open('xb') as stdout,(root/'build.stderr').open('xb') as stderr:
    process=subprocess.Popen(argv,stdout=stdout,stderr=stderr,start_new_session=True)
    print(json.dumps({'buildPID':process.pid,'records':str(root)}),flush=True)
    try:record['exitCode']=process.wait(timeout=900)
    except BaseException as error:
        record['supervisionError']=type(error).__name__+': '+str(error)
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        record['exitCode']=process.wait(timeout=10)
record['elapsedSeconds']=time.monotonic()-start
record['sourcePinsUnchanged']=all(hashlib.sha256((package/row['path']).read_bytes()).hexdigest()==row['sha256'] for row in record['sourcePins'])
record['streams']={name:{'bytes':(root/name).stat().st_size,'sha256':hashlib.sha256((root/name).read_bytes()).hexdigest()} for name in ('build.stdout','build.stderr')}
if record['exitCode']==0:
    binary=Path((root/'build.stdout').read_text().splitlines()[-1]);assert binary.is_file() and binary.name=='darkbloom-cluster-worker'
    record['nativePath']=str(binary);record['nativeSHA256']=hashlib.sha256(binary.read_bytes()).hexdigest()
    assert hashlib.sha256((binary.parent/'mlx.metallib').read_bytes()).hexdigest()==metalpin
(root/'execution.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if k not in ('sourcePins','dependencies','argv')}),flush=True)
raise SystemExit(0 if record['exitCode']==0 and record['sourcePinsUnchanged'] else 1)
