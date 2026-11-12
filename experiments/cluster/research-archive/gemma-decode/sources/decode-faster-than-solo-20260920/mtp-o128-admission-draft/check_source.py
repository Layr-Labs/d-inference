"""Small exact source closure/inverse checks. No compilation or test run."""
import hashlib,json
from pathlib import Path
D=Path(__file__).resolve().parent

def read(path,row):
 b=path.read_bytes();assert not path.is_symlink() and (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256']);return b
for row in json.loads((D/'source-inputs.json').read_bytes())['members']:read(D/row['path'],row)
spec=json.loads((D/'composition.json').read_bytes());base=json.loads(read(Path(spec['baseSources']['path']),spec['baseSources']))
files={x['path']:x for x in base['files']}
for row in spec['overlays']:
 assert files[row['target']]==row['before']
 before=read(D/'preimages'/Path(row['target']).name,row['before']).decode();after=read(Path(row['source']['path']),row['source']).decode();value=before
 for op in row['operations']:
  assert value.count(op['before'])==1;value=value.replace(op['before'],op['after'])
 assert value==after
 for op in reversed(row['operations']):
  assert value.count(op['after'])==1;value=value.replace(op['after'],op['before'])
 assert value==before
for row in spec['additions']:assert row['target'] not in files;read(Path(row['source']['path']),row['source'])
assert len(spec['overlays'])==2 and len(spec['additions'])==1
print(json.dumps(dict(status='source-checked',overlays=2,addedPurePolicy=1,baseSources=116,workspaceMutated=False,testsExecuted=False)))
