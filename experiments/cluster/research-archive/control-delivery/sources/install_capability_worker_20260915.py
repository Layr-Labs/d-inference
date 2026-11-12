from pathlib import Path
import hashlib,json,shlex,subprocess,time
R=Path('/Users/developer/DarkbloomDev/cluster-research');B=R/'cluster-runtime-capability-main-integration-20260915';O=B/'installed-metadata-1';O.mkdir(exist_ok=False)
build=json.loads((B/'native-build-1/execution.json').read_text());binary=Path(build['nativePath']);sha=build['nativeSHA256'];assert hashlib.sha256(binary.read_bytes()).hexdigest()==sha
remote='/Users/developer/DarkbloomDev/resident-capability-runtime-20260915'
ssh=['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=5']
code=r'''
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,time
base=Path(sys.argv[1]);wanted=sys.argv[2]; worker=base/'darkbloom-cluster-worker';assert hashlib.sha256(worker.read_bytes()).hexdigest()==wanted;worker.chmod(0o700)
old=Path('/Users/developer/DarkbloomDev/resident-lookahead128-runtime-20260915')
for name,sha in [('mlx.metallib','2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'),('mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal','4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149')]:
 src=old/name;assert hashlib.sha256(src.read_bytes()).hexdigest()==sha
 dest=base/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest);assert hashlib.sha256(dest.read_bytes()).hexdigest()==sha
model=Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
args=[str(worker),'--describe-runtime','--config',str(model/'config.json'),'--manifest',str(model/'manifest.json'),'--expected-executable-sha256',wanted]
t=time.monotonic();x=subprocess.run(args,capture_output=True,timeout=20)
assert x.returncode==0 and not x.stderr,(x.returncode,x.stderr.decode());assert len(x.stdout)<=16384
value=json.loads(x.stdout);assert value['runtimeBinarySHA256']==wanted
(base/'capability.json').write_bytes(x.stdout);os.chmod(base/'capability.json',0o600)
print(json.dumps({'nativeBinarySHA256':wanted,'exitCode':x.returncode,'elapsedSeconds':time.monotonic()-t,'capabilitySHA256':hashlib.sha256(x.stdout).hexdigest(),'capability':value,'actualInstalledMetadataBranchInvoked':True,'modelGenerationInvoked':False}))
'''
for host in ['darkbloom-24','darkbloom-48']:
 setup=subprocess.run(ssh+[host,shlex.join(['/usr/bin/python3','-c','from pathlib import Path; import sys; p=Path(sys.argv[1]); assert p.parent.is_dir() and not p.parent.is_symlink(); p.mkdir(mode=0o700,exist_ok=False)',remote])],capture_output=True,text=True,check=True,timeout=15)
 subprocess.run(['scp','-q','-o','BatchMode=yes',str(binary),host+':'+remote+'/darkbloom-cluster-worker'],capture_output=True,check=True,timeout=60)
 x=subprocess.run(ssh+[host,shlex.join(['/usr/bin/python3','-c',code,remote,sha])],capture_output=True,text=True,check=True,timeout=35)
 value=json.loads(x.stdout);assert value['capabilitySHA256']=='c29b91951320e856b42a5f7916c64d0ce1ad7514b53d5361a465744bd1fe42e0'
 (O/(host+'.json')).write_text(json.dumps(value,indent=2)+'\n');print(host,value['nativeBinarySHA256'],value['capabilitySHA256'],value['elapsedSeconds'],flush=True)
