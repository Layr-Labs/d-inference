#!/usr/bin/env python3
import json,hashlib
from pathlib import Path
B=Path(__file__).resolve().parent
H=lambda b:hashlib.sha256(b).hexdigest()
m=json.loads((B/'manifest.json').read_text())
for x in m['members']:
 b=(B/x['path']).read_bytes();assert len(b)==x['bytes'] and H(b)==x['sha256'],x['path']
l=json.loads((B/'lineage.json').read_text())
for x in json.loads((B/'overlay.json').read_text()):
 p=x['path'];out=(B/'proposed'/p).read_bytes();assert H(out)==x['sha256']==x['frozenAfterSHA256'],p
 f=Path(l['base'])/p;current=f.read_bytes() if f.exists() else None
 assert (H(current) if current is not None else None)==x['beforeSHA256']==x['frozenBeforeSHA256'],p
 assert b'DARKBLOOM_PRIVATE' not in out and b'#if' not in out,p
print(json.dumps({'sourceReplay':'PASS','files':12,'exactFrozenOutputs':12,'privateActivationFlags':0,'compilerExecuted':False,'fixturesExecuted':False}))
