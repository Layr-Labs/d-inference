import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'cluster-native-shared-request-go-coverage-draft-20260917'
OUTPUT=ROOT.parent/'cluster-native-shared-request-go-coverage-checks-1-20260917'
EXPECTED='8fc1cd2a20cc95ac18dbe1e0d2825a3d1ef17902cc1db14741aef1089f1a7d01'
sys.path.insert(0,str(SOURCE/'GoChecks'))
from check_process import run_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 assert sha(SOURCE/'manifest.json')==EXPECTED
 for row in json.loads((SOURCE/'manifest.json').read_bytes())['files']:
  p=SOURCE/row['path'];assert not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
phases=['source','prepare','focused','all'];p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('phase',choices=phases);a=p.parse_args();verify()
i=phases.index(a.phase)
if i:
 prior=json.loads((ROOT/('go-'+phases[i-1]+'-1/receipt.json')).read_text());assert prior['status']=='passed' and prior['manifestSHA256']==EXPECTED
out=ROOT/('go-'+a.phase+'-1');out.mkdir(mode=0o700);receipt=dict(status='failed',phase=a.phase,manifestSHA256=EXPECTED)
command=json.loads((SOURCE/'commands.json').read_text())['sequential'][i]
try:
 receipt['child']=run_owned(command,out,'execution',[30,120,340,1900][i],diagnostic_limit=16777216);verify()
 if a.phase in ['focused','all']:
  result=OUTPUT/('go-'+a.phase+'-1/checks.json');assert json.loads(result.read_text())['passed'] is True;receipt['resultSHA256']=sha(result)
 elif a.phase=='prepare':receipt['resultSHA256']=sha(OUTPUT/'preparation.json')
 receipt['status']='passed'
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
