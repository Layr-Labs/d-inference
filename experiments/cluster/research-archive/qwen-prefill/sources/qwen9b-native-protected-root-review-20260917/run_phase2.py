import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'qwen9b-native-protected-result-correction-20260917'
EXPECTED='522c622ecd3768ea0e81b1243ddd3debffaa98eff772546acd628f4331855144'
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
 prior=ROOT/(phases[phases.index(a.phase)-1]+'-2')/'receipt.json';j=json.loads(prior.read_bytes());assert j['status']=='passed' and j['wrapperManifestSHA256']==EXPECTED
out=ROOT/(a.phase+'-2');out.mkdir(mode=0o700)
receipt=dict(status='failed',phase=a.phase,wrapperManifestSHA256=EXPECTED,steps=[])
try:
 if a.phase=='prepare':
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'prepare.py')],out,'prepare',90));verify()
  result=SOURCE/'preparation-2/receipt.json';assert json.loads(result.read_bytes())['status']=='passed';receipt['resultSHA256']=sha(result)
 elif a.phase=='package':
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'package_native.py'),'runtime-2','worker-2','capability-2','native-2','runtime-bundle-2'],out,'execution',180));verify()
  receipt['resultSHA256']=sha(SOURCE/'runtime-bundle-2/bundle.json')
 else:
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'run_checks.py'),a.phase,a.phase+'-2'],out,'execution',1100));verify()
  result=SOURCE/(a.phase+'-2')/'receipt.json';assert json.loads(result.read_bytes())['status']=='passed';receipt['resultSHA256']=sha(result)
 receipt['status']='passed'
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
