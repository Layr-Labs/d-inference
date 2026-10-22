import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'gemma4-jaccl-startup-progress-draft-20260917'
EXPECTED='2299ee34c21c0e99be0a8501fca8daba1f999c9da11dc1bd319630f6d718b7f8'
sys.path.insert(0,str(SOURCE))
from check_process import run_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 assert sha(SOURCE/'manifest.json')==EXPECTED
 for r in json.loads((SOURCE/'manifest.json').read_bytes())['members']:
  p=SOURCE/r['path'];assert p.stat().st_size==r['bytes'] and sha(p)==r['sha256']
p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('phase',choices=['cpu','prepare']);a=p.parse_args();verify()
if a.phase=='prepare':assert json.loads((ROOT/'cpu-1/receipt.json').read_bytes())['status']=='passed'
out=ROOT/(a.phase+'-1');out.mkdir(mode=0o700);receipt=dict(status='failed',phase=a.phase,manifestSHA256=EXPECTED)
try:
 command=['/usr/bin/python3','-B',str(SOURCE/('check_cpu.py' if a.phase=='cpu' else 'prepare.py'))]+(['1'] if a.phase=='cpu' else [])
 receipt['child']=run_owned(command,out,'execution',60);verify()
 result=SOURCE/('cpu-1' if a.phase=='cpu' else 'preparation-1')/'receipt.json';assert json.loads(result.read_bytes())['status']=='passed'
 if a.phase=='cpu':
  output=(SOURCE/'cpu-1/checks.stderr').read_text();assert 'Ran 14 tests' in output and output.rstrip().endswith('OK')
 receipt.update(status='passed',resultSHA256=sha(result))
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
