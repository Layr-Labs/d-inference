"""Source/AST/pin verification only; does not run controls or read model payloads."""
from pathlib import Path
import ast,hashlib,json
ROOT=Path(__file__).resolve().parent
def check(row):
 p=Path(row['path']);assert p.is_file() and not p.is_symlink();b=p.read_bytes()
 assert (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256']);return json.loads(b)
for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:
 p=ROOT/row['path'];b=p.read_bytes();assert (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256'])
 if p.suffix=='.py':ast.parse(b,str(p))
spec=json.loads((ROOT/'inputs.json').read_bytes())
for key in ('batchSource','actualAppliedSource','actualCPUControls'):check(spec[key])
for kind,row in spec['harnesses'].items():
 for member in check(row)['members']:
  p=ROOT/kind/member['path'];b=p.read_bytes();assert (len(b),hashlib.sha256(b).hexdigest())==(member['bytes'],member['sha256'])
for kind in ('tiny','remote','local','numerical'):
 for row in json.loads((ROOT/kind/'batch-predecessor.json').read_bytes()).values():check(row)
print(json.dumps(dict(sourceChecksPassed=True,testsExecuted=False,nativeExecuted=False)))
