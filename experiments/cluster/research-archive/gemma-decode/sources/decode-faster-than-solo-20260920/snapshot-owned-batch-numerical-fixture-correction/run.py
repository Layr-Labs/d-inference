"""Root-owned six-fixture retry; original reader/harness bytes stay frozen."""
import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:
  p=ROOT/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
 spec=json.loads((ROOT/'inputs.json').read_bytes())
 for row in spec.values():
  p=Path(row['path']);assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
 base=Path(spec['predecessor']['path']).parent
 for row in json.loads((base/'source-inputs.json').read_bytes())['members']:
  p=base/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
 return spec
p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--run',action='store_true');p.add_argument('--output',type=Path);a=p.parse_args();spec=verify()
if not a.run:
 assert a.output is None;print(json.dumps(dict(sourceChecksPassed=True,testsExecuted=False)));sys.exit(0)
assert a.output is not None and a.output.is_absolute() and a.output.parent.resolve()==a.output.parent;a.output.mkdir(mode=0o700)
sys.path.insert(0,str(Path(spec['ownedHelper']['path']).parent));from owned_process import invoke_controller
record=dict(schema='gemma4_owned_batch_numerical_fixture_retry_v1',expectedMethods=6,sourceManifestSHA256=sha(ROOT/'source-inputs.json'),inputs=spec,modelExecuted=False,nativeExecuted=False,sshExecuted=False)
try:
 with (a.output/'stdout').open('xb') as out,(a.output/'stderr').open('xb') as err:
  invoke_controller(['/usr/bin/python3','-B',str(ROOT/'Tests/test_join.py'),'-v'],out,err,record,timeout=30)
 assert record['exitCode']==0 and record['reaped'] is True and record['groupAbsent'] is True and record['killedOwnedGroup'] is False
 text=(a.output/'stderr').read_text();assert '\nRan 6 tests in ' in text and text.rstrip().endswith('OK')
 assert verify()==spec;record['status']='passed'
except BaseException as e:
 record.update(status='failed',error=type(e).__name__+': '+str(e));raise
finally:
 for name in ['stdout','stderr']:
  f=a.output/name
  if f.exists():record[name+'SHA256']=sha(f);record[name+'Bytes']=f.stat().st_size
 with (a.output/'receipt.json').open('x') as f:json.dump(record,f,indent=2);f.write('\n')
 print(json.dumps(record))
