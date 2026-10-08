"""Verify only current source pins/AST and the preserved O128 preparation authority."""
from pathlib import Path
import ast,hashlib,json
ROOT=Path(__file__).resolve().parent
for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:
 p=ROOT/row['path'];assert p.is_file() and not p.is_symlink()
 b=p.read_bytes();assert (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256'])
 if p.suffix=='.py':ast.parse(b,str(p))
authority=json.loads((ROOT/'o128-provenance.json').read_bytes())
for row in [authority['draft'],authority['actualBuildReceipt'],authority['actualSources']]:
 p=Path(row['path']);assert p.is_file() and not p.is_symlink();b=p.read_bytes()
 assert (len(b),hashlib.sha256(b).hexdigest())==(row['bytes'],row['sha256'])
print(json.dumps(dict(status='source-checked',testsExecuted=False,modelExecuted=False)))
