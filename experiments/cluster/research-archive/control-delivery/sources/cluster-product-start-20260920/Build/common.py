import hashlib,json,sys
from pathlib import Path
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent
sys.dont_write_bytecode=True

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(path,value):Path(path).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
def require(test,message):
    if not test:raise ValueError(message)
def inputs():
    for row in json.loads((ROOT/'manifest.json').read_bytes())['members']:
        p=ROOT/row['path'];require(p.is_file() and not p.is_symlink() and sha(p)==row['sha256'] and p.stat().st_size==row['bytes'],'Frozen source changed: '+row['path'])
    c=json.loads((BASE/'composition.json').read_bytes());w=Path(c['workspace'])
    require(w.resolve()==w and w!=ROOT.parent.parent/'d-inference','Exact private workspace required')
    before=json.loads(Path(c['priorInventoryPath']).read_bytes());after=json.loads((BASE/'candidate-after.json').read_bytes())
    require(sha(c['priorInventoryPath'])==c['priorInventorySHA256'] and sha(BASE/'candidate-after.json')==c['candidateInventorySHA256'],'Inventory authority changed')
    helper=Path(c['helperDirectory']);require(sha(helper/'checks.json')==c['helperReceiptSHA256'],'Qualified helper receipt changed')
    h=json.loads((helper/'checks.json').read_bytes());require(h['passed'] is True,'Qualified helper required')
    for row in h['artifacts']:require(sha(row['path'])==row['sha256'] and Path(row['path']).stat().st_size==row['bytes'],'Helper artifact changed')
    return c,w,before,after
