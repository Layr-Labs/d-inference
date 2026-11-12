from pathlib import Path
import hashlib,json
ROOT=Path('/Users/developer/DarkbloomDev/d-inference')
MEMBER=Path('/Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-draft-20260915/proposed')
OUT=Path(__file__).parent
paths=['coordinator/protocol/messages.go','coordinator/registry/provider.go','coordinator/registry/provider_lifecycle.go','coordinator/api/provider.go','coordinator/api/server.go','coordinator/api/server_config.go']
rows=[]
for p in paths:
 source=MEMBER/p if (MEMBER/p).is_file() else ROOT/p
 data=source.read_bytes()
 for directory in ['originals','proposed']:
  dest=OUT/directory/p;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
 rows.append({'path':p,'base':str(source),'sha256':hashlib.sha256(data).hexdigest(),'mainSHA256':hashlib.sha256((ROOT/p).read_bytes()).hexdigest()})
(OUT/'base-inputs.json').write_text(json.dumps(rows,indent=2)+'\n')
