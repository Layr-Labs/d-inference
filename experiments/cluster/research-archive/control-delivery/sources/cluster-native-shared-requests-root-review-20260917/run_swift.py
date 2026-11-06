import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'cluster-native-member-shared-requests-swift-reuse-v2-20260917'
OUTPUT=ROOT.parent/'cluster-native-member-shared-requests-swift-checks-2-20260917'
EXPECTED='432f24932fcab4c16d05978e72bc2d067f9a2d7a02c3780f0af1cb9813ca78f2'
sys.path.insert(0,str(SOURCE))
from check_process import run_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 assert sha(SOURCE/'manifest.json')==EXPECTED
 for row in json.loads((SOURCE/'manifest.json').read_bytes())['files']:
  p=SOURCE/row['path'];assert not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
p=argparse.ArgumentParser(allow_abbrev=False);phases=['controls','prepare','helper','tests','build'];p.add_argument('phase',choices=phases);a=p.parse_args();verify()
if a.phase!='controls':
 prior=json.loads((ROOT/('swift-'+phases[phases.index(a.phase)-1]+'-1/receipt.json')).read_text());assert prior['status']=='passed' and prior['manifestSHA256']==EXPECTED
out=ROOT/('swift-'+a.phase+'-1');out.mkdir(mode=0o700);receipt=dict(status='failed',phase=a.phase,manifestSHA256=EXPECTED)
if a.phase=='controls':command=['/usr/bin/python3','-B',str(SOURCE/'test_coverage.py')];timeout=30
elif a.phase=='prepare':command=['/usr/bin/python3','-B',str(SOURCE/'prepare.py'),'--apply'];timeout=150
else:command=['/usr/bin/python3','-B',str(SOURCE/'run.py'),'--prepared',str(OUTPUT),'--phase',a.phase,'--attempt','1'];timeout=1200
try:
 receipt['child']=run_owned(command,out,'execution',timeout);verify()
 if a.phase=='controls':
  raw=(out/'execution.stderr').read_text();assert 'Ran 4 tests' in raw and raw.rstrip().endswith('OK')
 else:
  result=OUTPUT/('preparation.json' if a.phase=='prepare' else a.phase+'-1/checks.json');j=json.loads(result.read_text())
  assert (j['wrapperManifestSHA256']==EXPECTED if a.phase=='prepare' else j['passed'] is True)
  receipt['resultSHA256']=sha(result)
 receipt['status']='passed'
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
