from pathlib import Path
import concurrent.futures,hashlib,json,shlex,subprocess
parent=Path(__file__).resolve().parent;base=parent.parent
assert hashlib.sha256((parent/'manifest.json').read_bytes()).hexdigest()=='a3d6f4f8b93dea176ff435efc5d11776883eb79b2e2339a897a0f8308d54a3bd'
for name,row in json.loads((parent/'manifest.json').read_bytes())['files'].items():
 p=parent/name;assert p.stat().st_size==row['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256']
out=parent/'root-preflight-1';out.mkdir(mode=0o700)
script='''from pathlib import Path
import hashlib,json,os,stat,subprocess,sys
expected=json.load(sys.stdin)
roots={'owner':Path('/Users/developer/DarkbloomDev/owner-native-mtp-probe-20260915'),'runtime':Path('/Users/developer/DarkbloomDev/qwen-mtp-registered-probe-runtime-20260915')}
for name,row in expected.items():
 label,relative=name.split('/',1);p=roots[label]/relative;st=p.lstat()
 assert stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and st.st_uid==os.geteuid() and not(st.st_mode&0o022)
 assert st.st_size==row['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'],name
sys.path.insert(0,str(roots['owner']));sys.dont_write_bytecode=True
from reference_resources import sample_local,validate_local
resource=sample_local();validate_local(resource)
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
names={'darkbloom','cluster-inference','darkbloom-cluster-worker','darkbloom-owner-qualification','owner-controller'}
active=[s.strip() for s in ps.splitlines() if len(s.split(maxsplit=1))==2 and Path(s.split(maxsplit=1)[1]).name in names]
assert not active,active
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');assert not journal.is_symlink() and journal.stat().st_size==0
assert not list((roots['owner']/'evidence').iterdir()),'Existing MTP candidate evidence'
print(json.dumps(dict(verifiedMembers=len(expected),active=active,journalBytes=0,resource=resource)))
'''
(out/'remote.py').write_text(script)
def check(rank):
 expected=json.loads((base/f'qwen-resident-mtp-registered-probe-deployment-20260915/rank{rank}.stdout.json').read_text())['verified']
 r=subprocess.run(['/usr/bin/ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=8',f'darkbloom-{24 if rank==0 else 48}',shlex.join(['/usr/bin/python3','-B','-c',script])],input=json.dumps(expected).encode(),capture_output=True,timeout=30)
 (out/f'rank{rank}.stdout').write_bytes(r.stdout);(out/f'rank{rank}.stderr').write_bytes(r.stderr)
 assert r.returncode==0 and not r.stderr,(rank,r.stderr.decode(errors='replace'))
 value=json.loads(r.stdout);return dict(rank=rank,verifiedMembers=value['verifiedMembers'],actualFreeBytes=value['resource']['actualFreeBytes'],journalBytes=value['journalBytes'])
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(check,[0,1]))
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results))
