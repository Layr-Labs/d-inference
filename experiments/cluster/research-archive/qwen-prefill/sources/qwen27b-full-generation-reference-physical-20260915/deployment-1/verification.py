import sys,json,hashlib,os,stat
from pathlib import Path
root=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor')
sys.path.insert(0,str(root));sys.dont_write_bytecode=True
from reference_inputs import Pins,verify_launcher,verify_inputs,validate_job
from binding_common import parse
from reference_resources import sample_local,validate_local
pins=Pins();verify_launcher(root,'39cd3e56d95ab152362f7f060ce6311c8f51e221fd737e3cb2e2fa8d401b7dac',pins)
raw=(root/'example-job.json').read_bytes();assert hashlib.sha256(raw).hexdigest()=='984b013420e00c620842446af1d22b28eca941a50994875d3e64c809b5fc1e85'
job=validate_job(parse(raw));prompt,tokens=verify_inputs(job,pins);pins.recheck()
actual=set()
for d,ds,fs in os.walk(root,followlinks=False):
 for p in [Path(d)]+[Path(d)/n for n in ds+fs]:
  st=p.lstat();assert st.st_uid==os.geteuid() and not stat.S_ISLNK(st.st_mode) and not(st.st_mode&0o022)
  if p.is_file():actual.add(p.relative_to(root).as_posix())
expected={r['path'] for r in json.loads((root/'manifest.json').read_bytes())['files']}|{'manifest.json'}
assert actual==expected
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');assert journal.stat().st_size==0
resource=sample_local();validate_local(resource)
print(json.dumps(dict(verified=True,launcherMembers=len(actual),promptCount=len(tokens),canonicalJournalBytes=0,resource=resource,modelExecuted=False),sort_keys=True))
