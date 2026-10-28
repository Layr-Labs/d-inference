from pathlib import Path
import sys,json,os,stat,hashlib
root=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor-diagnostics')
for p in [root]+list(root.rglob('*')):
 st=p.lstat();assert not stat.S_ISLNK(st.st_mode) and st.st_uid==os.geteuid()
 assert stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)
 p.chmod(0o700 if p.is_dir() else 0o600)
sys.path.insert(0,str(root));sys.dont_write_bytecode=True
from reference_inputs import Pins,verify_launcher,verify_inputs,validate_job
from binding_common import parse
pins=Pins();verify_launcher(root,'43c4dcaaef9ec06b51379146606f664fcfebdf5c98aeaf49c0e578183dc9273c',pins)
raw=(root/'example-job.json').read_bytes();assert hashlib.sha256(raw).hexdigest()=='ba3526948eda95468059088b18104dcfad9c2b923dba5078e0bc91b3aff7d639'
job=validate_job(parse(raw));prompt,tokens=verify_inputs(job,pins);pins.recheck()
expected={r['path'] for r in json.loads((root/'manifest.json').read_bytes())['files']}|{'manifest.json'}
assert {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}==expected
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
print(json.dumps(dict(verified=True,members=len(expected),promptCount=len(tokens),canonicalJournalBytes=journal.stat().st_size,modelExecuted=False,launchAuthorizedByThisCopy=False)))
