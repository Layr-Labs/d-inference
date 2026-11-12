"""Small source/pin/AST checks only. No test, artifact or remote execution."""
from pathlib import Path
import ast,hashlib,json
ROOT=Path(__file__).resolve().parent
m=json.loads((ROOT/'source-inputs.json').read_bytes())
for row in m['members']:
 p=ROOT/row['path'];raw=p.read_bytes();assert not p.is_symlink() and len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
 if p.suffix=='.py':ast.parse(raw,str(p))
lineage=json.loads((ROOT/'predecessor-inputs.json').read_bytes())
for row in lineage['members']:
 old=Path(row['source']).read_bytes();new=(ROOT/row['path']).read_bytes()
 assert hashlib.sha256(old).hexdigest()==row['beforeSHA256'] and hashlib.sha256(new).hexdigest()==row['sha256']
 if row.get('unchangedRequired'):assert old==new,row['path']
print(json.dumps(dict(status='passed',members=len(m['members']),predecessorPins=len(lineage['members']),testsExecuted=False,nativeExecuted=False,remoteExecuted=False)))
