"""Root-only bounded CPU tests; no lease, SSH, models or compiler."""
import argparse,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT))
from owned_process import invoke_controller
from activation import sha
p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
assert a.output.is_absolute() and a.output.parent.resolve()==a.output.parent;a.output.mkdir(mode=0o700)
record=dict(schema='gemma4_remote_mtp_cpu_controls_v1',expectedMethods=16,modelExecuted=False,sshExecuted=False)
with (a.output/'stdout').open('xb') as out,(a.output/'stderr').open('xb') as err:
    invoke_controller(['/usr/bin/python3','-B',str(ROOT/'Tests/test_contract.py'),'-v'],out,err,record,timeout=30)
record['stdoutSHA256']=sha(a.output/'stdout');record['stderrSHA256']=sha(a.output/'stderr')
with (a.output/'receipt.json').open('x') as f:json.dump(record,f,indent=2);f.write('\n')
assert record['exitCode']==0 and record['reaped'] is True and record['groupAbsent'] is True
text=(a.output/'stderr').read_text();assert '\nRan 16 tests in ' in text and text.rstrip().endswith('OK')
print(json.dumps(record))
