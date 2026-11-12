import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'qwen9b-native-protected-scope-fixture-correction-20260917'
EXPECTED='b05141ec68aa28442cf931f2d853292c4d23a4dfb96f51aea5e4685311710d90'
sys.path.insert(0,str(SOURCE))
from check_process import run_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 assert sha(SOURCE/'manifest.json')==EXPECTED
 for row in json.loads((SOURCE/'manifest.json').read_bytes())['files']:
  p=SOURCE/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('phase',choices=['prepare','runtime','worker','capability','native','package']);a=p.parse_args();verify()
phases=['prepare','runtime','worker','capability','native','package']
if a.phase!='prepare':
 prior=ROOT/(phases[phases.index(a.phase)-1]+'-3')/'receipt.json';j=json.loads(prior.read_bytes());assert j['status']=='passed' and j['wrapperManifestSHA256']==EXPECTED
out=ROOT/(a.phase+'-3');out.mkdir(mode=0o700)
receipt=dict(status='failed',phase=a.phase,wrapperManifestSHA256=EXPECTED,steps=[])
try:
 if a.phase=='prepare':
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'prepare.py')],out,'prepare',90));verify()
  result=SOURCE/'preparation-3/receipt.json';assert json.loads(result.read_bytes())['status']=='passed';receipt['resultSHA256']=sha(result)
 elif a.phase=='package':
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'package_native.py'),'runtime-3','worker-3','capability-3','native-3','runtime-bundle-3'],out,'execution',180));verify()
  receipt['resultSHA256']=sha(SOURCE/'runtime-bundle-3/bundle.json')
 else:
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'run_checks.py'),a.phase,a.phase+'-3'],out,'execution',1100));verify()
  result=SOURCE/(a.phase+'-3')/'receipt.json';assert json.loads(result.read_bytes())['status']=='passed';receipt['resultSHA256']=sha(result)
 receipt['status']='passed'
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
