from pathlib import Path
import json,os,subprocess,sys
root=Path('/Users/developer/DarkbloomDev/qwen27b-resident-solo-short-generation-20260916')
sys.path.insert(0,str(root/'supervisor'));sys.dont_write_bytecode=True
from reference_resources import sample_local,validate_local
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
names={'darkbloom','cluster-inference','darkbloom-cluster-worker','darkbloom-owner-qualification','owner-controller'}
active=[s.strip() for s in ps.splitlines() if len(s.split(maxsplit=1))==2 and Path(s.split(maxsplit=1)[1]).name in names]
assert not active,active
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');assert journal.is_file() and not journal.is_symlink() and journal.stat().st_size==0
resource=sample_local();validate_local(resource)
print(json.dumps(dict(kind='root_reference_preflight',active=active,journalBytes=0,resource=resource)),flush=True)
os.chdir(root/'supervisor')
os.execv('/usr/bin/python3',['/usr/bin/python3','-B',str(root/'supervisor/run_solo.py'),'--job',str(root/'supervisor/job.json'),'--job-sha256','8500b7992db44ea9312679d73a315498addd924c89f82d148876ff5bb2ea0f96','--launcher-sha256','9ba9fc268bc3439add530dcefa6e1d096ff1562518996e48aa413e2ef86a70a9'])
