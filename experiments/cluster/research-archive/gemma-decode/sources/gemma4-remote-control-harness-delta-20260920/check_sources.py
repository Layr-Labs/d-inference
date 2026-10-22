import ast,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def check(p,row):
    b=p.read_bytes();assert not p.is_symlink() and len(b)==row['bytes'] and hashlib.sha256(b).hexdigest()==row['sha256'],str(p)
for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:check(ROOT/row['path'],row)
c=json.loads((ROOT/'composition.json').read_bytes())
for name in ['depthHarnessPredecessor','nativeCounterContract','nativeReportContract','nativeEntryContract']:
    row=c[name];check(Path(row['path']),row)
for row in c['files']:
    if row['before']:
        check(Path(row['before']['path']),row['before']);check(ROOT/'preimages'/row['path'],row['before'])
    check(ROOT/row['source'],row['after'])
for p in ROOT.rglob('*.py'):ast.parse(p.read_text(),filename=str(p))
print(json.dumps(dict(status='passed',sourceOnly=True,overlays=2,testsExecuted=False,nativeExecuted=False)))
