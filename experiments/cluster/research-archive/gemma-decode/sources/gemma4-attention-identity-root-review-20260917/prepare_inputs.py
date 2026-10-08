import hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'gemma4-attention-identity-physical-draft-20260917'
EXPECTED='c504d32e124b2504a00f50db2d0a22534ea64a2762f6918668f3e38b821d13fd'
sys.path.insert(0,str(SOURCE))
from check_process import run_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(SOURCE/'manifest.json')==EXPECTED
for row in json.loads((SOURCE/'manifest.json').read_bytes())['members']:assert sha(SOURCE/row['path'])==row['sha256']
assert json.loads((ROOT/'package-1/receipt.json').read_bytes())['status']=='passed'
out=ROOT/'inputs-1';out.mkdir(mode=0o700)
receipt=dict(status='failed',sourceManifestSHA256=EXPECTED)
try:
 receipt['child']=run_owned(['/usr/bin/python3','-B',str(SOURCE/'prepare_inputs.py'),'--source-sha256',EXPECTED,'--build-receipt-sha256','88bab3e871028892188472ccf7c49d924a2a519298f5b578b1684244776d0435'],out,'execution',120)
 p=SOURCE/'actual-inputs-1/receipt.json';assert json.loads(p.read_bytes())['status']=='passed';receipt.update(status='passed',preparationSHA256=sha(p))
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
