from pathlib import Path
import subprocess,time,json,hashlib,sys
base=Path('/Users/developer/DarkbloomDev/d-inference');out=Path(__file__).resolve().parent
run=out/sys.argv[1];view=run/'workspace';view.mkdir(parents=True,exist_ok=False)
def overlay(src,delta,dest):
 dest.mkdir(exist_ok=True)
 names=set(x.name for x in src.iterdir()) if src.exists() else set()
 if delta.exists(): names|={x.name for x in delta.iterdir()}
 for n in names:
  a,b,c=src/n,delta/n,dest/n
  if b.is_dir(): overlay(a,b,c)
  elif b.is_file(): c.write_bytes(b.read_bytes());c.chmod(b.stat().st_mode&0o777)
  else: c.symlink_to(a,target_is_directory=a.is_dir())
overlay(base,out/'proposed',view)
files=[]
for mod in ['DarkbloomClusterProtocol','DarkbloomClusterProcess','DarkbloomClusterRemote','DarkbloomClusterBootstrap']:
 files+=list((view/'libs/darkbloom-cluster/Sources'/mod).glob('*.swift'))
for group in ['Installed','Diagnostics']:
 files+=list((view/'provider-swift/Sources/ProviderCore/Inference/Distributed'/group).glob('*.swift'))
files+=list((view/'provider-swift/Tests/ClusterDiagnosticsChecks').glob('*'))
files+=list((view/'provider-swift/Tests/ClusterInstalledSessionChecks').glob('*'))
files+=list((view/'provider-swift/Sources/ProviderCore/Config').glob('Cluster*.swift'))
files+=[view/p for p in ['provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedRequestDeadlineContext.swift','provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedResidentExecution.swift','provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedPipeExecutionOwner.swift','provider-swift/Sources/ProviderCoreFoundation/Manifest.swift','libs/darkbloom-cluster/Tests/ProcessChecks/MLXLMCommonContractValues.swift','libs/darkbloom-cluster/Tests/ProcessChecks/FakeClusterWorker.swift']]
pins=[{'path':str(p.relative_to(view)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(set(files)) if p.is_file()]
(run/'source-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
start=time.monotonic();r=subprocess.run(['bash',str(view/'provider-swift/Tests/ClusterDiagnosticsChecks/run.sh')],cwd=view,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
(run/'stdout.txt').write_bytes(r.stdout);(run/'stderr.txt').write_bytes(r.stderr)
receipt={'exitCode':r.returncode,'elapsedSeconds':time.monotonic()-start,'stdoutSHA256':hashlib.sha256(r.stdout).hexdigest(),'stderrSHA256':hashlib.sha256(r.stderr).hexdigest(),'sourcePinsSHA256':hashlib.sha256((run/'source-pins.json').read_bytes()).hexdigest(),'allPinnedSourcesUnchanged':all(hashlib.sha256((view/p['path']).read_bytes()).hexdigest()==p['sha256'] for p in pins)}
(run/'result.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));print(r.stdout.decode());print(r.stderr.decode())
