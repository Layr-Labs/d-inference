import argparse, hashlib, json, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'gemma4-attention-identity-correction-20260917'
EXPECTED='d88473104ae45164e81f4e55a1722015ae1fed81b82677af31eaef7e48c86821'
sys.path.insert(0,str(SOURCE))
from check_process import run_owned

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def verify():
    assert sha(SOURCE/'manifest.json')==EXPECTED
    for row in json.loads((SOURCE/'manifest.json').read_text())['members']:
        assert sha(SOURCE/row['path'])==row['sha256']

p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('phase',choices=['prepare','build','package']);a=p.parse_args();verify()
if a.phase!='prepare':
    before='prepare' if a.phase=='build' else 'build'
    v=json.loads((ROOT/(before+'-1')/'receipt.json').read_text());assert v['status']=='passed' and v['sourceManifestSHA256']==EXPECTED
out=ROOT/(a.phase+'-1');out.mkdir(mode=0o700)
command=['/usr/bin/python3','-B',str(SOURCE/(a.phase+'.py'))]
if a.phase!='prepare':command+=['native-1']
receipt=dict(status='failed',phase=a.phase,sourceManifestSHA256=EXPECTED)
try:
    receipt['child']=run_owned(command,out,'execution',{'prepare':180,'build':1020,'package':180}[a.phase]);verify()
    result=SOURCE/('preparation/receipt.json' if a.phase=='prepare' else 'native-1/receipt.json' if a.phase=='build' else 'native-1-bundle/bundle.json')
    value=json.loads(result.read_text())
    if a.phase!='package':assert value['status']=='passed'
    receipt.update(status='passed',resultSHA256=sha(result))
finally:
    with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
