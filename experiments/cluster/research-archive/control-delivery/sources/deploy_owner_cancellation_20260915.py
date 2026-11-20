from pathlib import Path
import base64, hashlib, json, shlex, subprocess, sys
R=Path('/Users/developer/DarkbloomDev/cluster-research')
B=R/'owner-wakeup-qualification-bundle-20260915'
N=R/'resident-lookahead128-bundle-20260915'
SSH=['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=5']
REMOTE_CODE=r'''
from pathlib import Path
import base64,hashlib,json,os,stat,subprocess,sys
x=json.load(sys.stdin)
base=Path(x['remote'])
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
processes=[s.strip() for s in ps.splitlines() if Path(s.split(maxsplit=1)[1]).name in ['darkbloom-cluster-worker','darkbloom-owner-qualification']]
assert not processes, processes
journals=[]
for p in Path('/Users/developer/DarkbloomDev').glob('owner-*/lease/*'):
 if p.is_file() and ('journal' in p.name or p.name == 'native-device.lease'):
  assert p.stat().st_size==0,str(p)
  journals.append(str(p))
assert base.parent.is_dir() and not base.parent.is_symlink()
base.mkdir(mode=0o700,exist_ok=False)
for f in x['files']:
 p=base/f['path'];p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 data=base64.b64decode(f['data'],validate=True)
 assert hashlib.sha256(data).hexdigest()==f['sha256']
 fd=os.open(str(p),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o700 if f['executable'] else 0o600)
 with os.fdopen(fd,'wb') as o:o.write(data)
for d in ['lease','evidence']: (base/d).mkdir(mode=0o700)
checks=[]
for f in x['files']+x['nativeFiles']:
 p=(base/f['path']) if 'data' in f else Path('/Users/developer/DarkbloomDev/resident-lookahead128-runtime-20260915')/f['path']
 assert stat.S_ISREG(p.lstat().st_mode) and not p.is_symlink()
 h=hashlib.sha256(p.read_bytes()).hexdigest();assert h==f['sha256'],str(p)
 checks.append({'path':str(p),'sha256':h,'bytes':p.stat().st_size})
assert not (base/'libDarkbloomClusterRuntime.dylib').exists()
print(json.dumps({'verified':checks,'previousZeroJournals':journals,'processes':processes}))
'''
for mode in ['before-first','after-decode']:
 p=R/f'owner-cancellation-{mode}-20260915'
 for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
  receipt=p/f'deployment-{rank}.json'
  assert not receipt.exists()
  files=[]
  for f in json.loads((B/'bundle.json').read_text())['files']:
   b=(B/f['path']).read_bytes();assert hashlib.sha256(b).hexdigest()==f['sha256']
   files.append({'path':f['path'],'sha256':f['sha256'],'data':base64.b64encode(b).decode(),'executable':f['path']=='darkbloom-owner-qualification'})
  for src,dest in [(f'configuration/owner-rank{rank}.json','owner.json'),('configuration/matrix.json','matrix.json'),('monitor.py','monitor.py'),('reference_resources.py','reference_resources.py'),('stage_checks/common.py','stage_checks/common.py'),('stage_checks/__init__.py','stage_checks/__init__.py')]:
   b=(p/src).read_bytes();files.append({'path':dest,'sha256':hashlib.sha256(b).hexdigest(),'data':base64.b64encode(b).decode(),'executable':False})
  payload={'remote':f'/Users/developer/DarkbloomDev/{p.name}','files':files,'nativeFiles':json.loads((N/'bundle.json').read_text())['files']}
  result=subprocess.run(SSH+[host,shlex.join(['/usr/bin/python3','-c',REMOTE_CODE])],input=json.dumps(payload),capture_output=True,text=True,timeout=40)
  receipt.write_text(json.dumps({'host':host,'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr},indent=2)+'\n')
  print(mode,host,result.returncode,flush=True)
  if result.returncode:sys.exit(1)
