"""Only immutable source/AST checks. No tests, payload, native or remote actions."""
from pathlib import Path
import ast,hashlib,json
ROOT=Path(__file__).resolve().parent
for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:
 p=ROOT/row['path'];assert p.is_file() and not p.is_symlink()
 b=p.read_bytes();assert (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256'])
 if p.suffix=='.py':ast.parse(b,str(p))
prior=json.loads((ROOT/'batch-predecessor.json').read_bytes())
for row in prior.values():
 p=Path(row['path']);assert p.is_file() and not p.is_symlink();b=p.read_bytes()
 assert (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256'])
print(json.dumps(dict(sourceChecksPassed=True,testsExecuted=False,nativeExecuted=False)))
