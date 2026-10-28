import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'qwen9b-native-protected-build-draft-20260917'
EXPECTED='2ea9e9cd6da7bd8a268d8f3491ca19c4753a5eafdb121959c7dd2c999b4a2a95'
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
 prior=ROOT/(phases[phases.index(a.phase)-1]+'-1')/'receipt.json';j=json.loads(prior.read_bytes());assert j['status']=='passed' and j['wrapperManifestSHA256']==EXPECTED
out=ROOT/(a.phase+'-1');out.mkdir(mode=0o700)
receipt=dict(status='failed',phase=a.phase,wrapperManifestSHA256=EXPECTED,steps=[])
try:
 if a.phase=='prepare':
  for name in ['sources','cache','snapshot']:
   receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'prepare.py'),name],out,name,210));verify()
 elif a.phase=='package':
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'package_native.py'),'runtime-1','worker-1','capability-1','native-1','runtime-bundle-1'],out,'execution',180));verify()
  receipt['resultSHA256']=sha(SOURCE/'runtime-bundle-1/bundle.json')
 else:
  receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'run_checks.py'),a.phase,a.phase+'-1'],out,'execution',1100));verify()
  result=SOURCE/(a.phase+'-1')/'receipt.json';assert json.loads(result.read_bytes())['status']=='passed';receipt['resultSHA256']=sha(result)
 receipt['status']='passed'
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
