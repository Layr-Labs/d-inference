"""Root-only bounded six-control run; no model or native execution."""
import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
spec=json.loads((ROOT/'inputs.json').read_bytes());harness=Path(spec['remoteHarness']['path']).parent
assert hashlib.sha256((harness/'source-inputs.json').read_bytes()).hexdigest()==spec['remoteHarness']['sha256']
manifest=json.loads((harness/'source-inputs.json').read_bytes())
for row in manifest['members']:
 raw=(harness/row['path']).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
sys.path.insert(0,str(harness));from owned_process import invoke_controller
p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
assert a.output.is_absolute() and a.output.parent.resolve()==a.output.parent;a.output.mkdir(mode=0o700)
record=dict(schema='gemma4_remote_numerical_join_cpu_controls_v1',expectedMethods=6,modelExecuted=False,sshExecuted=False)
with (a.output/'stdout').open('xb') as out,(a.output/'stderr').open('xb') as err:
 invoke_controller(['/usr/bin/python3','-B',str(ROOT/'Tests/test_join.py'),'-v'],out,err,record,timeout=30)
for name in ['stdout','stderr']:record[name+'SHA256']=hashlib.sha256((a.output/name).read_bytes()).hexdigest()
with (a.output/'receipt.json').open('x') as f:json.dump(record,f,indent=2);f.write('\n')
assert record['exitCode']==0 and record['reaped'] is True and record['groupAbsent'] is True
text=(a.output/'stderr').read_text();assert '\nRan 6 tests in ' in text and text.rstrip().endswith('OK')
print(json.dumps(record))
