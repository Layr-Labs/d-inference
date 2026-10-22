"""Small source-only pins/AST; never read model/native/sidecar bytes."""
from pathlib import Path
import ast,hashlib,json
ROOT=Path(__file__).resolve().parent
def verify(path,row):
 raw=path.read_bytes();assert not path.is_symlink() and len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],path
 return raw
m=json.loads((ROOT/'source-inputs.json').read_bytes())
for row in m['members']:
 raw=verify(ROOT/row['path'],row)
 if row['path'].endswith('.py'):ast.parse(raw,row['path'])
spec=json.loads((ROOT/'inputs.json').read_bytes())
for row in spec['readers']:assert verify(ROOT/row['path'],row)==verify(Path(row['source']),row)
for row in [spec['remoteHarness'],spec['localHarness']]+spec['producerSources']:verify(Path(row['path']),row)
print(json.dumps(dict(status='passed',members=len(m['members']),exactReaderCopies=3,testsExecuted=False,modelExecuted=False)))
