from pathlib import Path
import json,os,subprocess,sys
root=Path('/Users/developer/DarkbloomDev/qwen27b-resident-solo-generation-20260915')
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
os.execv('/usr/bin/python3',['/usr/bin/python3','-B',str(root/'supervisor/run_solo.py'),'--job',str(root/'supervisor/job.json'),'--job-sha256','435d2e1e22d259ebff09d468ce2638a5d3c52c56ee12b9023d6c122d7f550d6d','--launcher-sha256','b94cc8cebf02eecb2bec79642e9647973dcc1b1e5ed0ff052c989e8334625aa9'])
