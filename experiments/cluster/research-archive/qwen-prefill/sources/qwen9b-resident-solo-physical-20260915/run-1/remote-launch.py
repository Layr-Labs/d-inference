from pathlib import Path
import json,os,subprocess,sys
root=Path('/Users/developer/DarkbloomDev/qwen9b-resident-solo-generation-20260915')
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
os.execv('/usr/bin/python3',['/usr/bin/python3','-B',str(root/'supervisor/run_solo.py'),'--job',str(root/'supervisor/job.json'),'--job-sha256','da9b19233d6ca24879c1ee6ccafbc8ae7dd509eb70ce43f9d796f1709941bd37','--launcher-sha256','c59521b53eeac0b7fcf213c44e3058c2bcd530da3f73ee762e4e5a77c40568c7'])
