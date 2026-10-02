from pathlib import Path
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
