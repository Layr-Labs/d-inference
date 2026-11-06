"""Source inverse checks only. No compiler, fixture or workspace mutation."""
import hashlib,json
from pathlib import Path
D=Path(__file__).resolve().parent
def sha(b):return hashlib.sha256(b).hexdigest()
def read(path,expected):
 b=path.read_bytes();assert(len(b),sha(b))==(expected['bytes'],expected['sha256']);return b
for row in json.loads((D/'source-inputs.json').read_bytes())['members']:read(D/row['path'],row)
spec=json.loads((D/'composition.json').read_bytes());base=json.loads(read(Path(spec['baseSources']['path']),spec['baseSources']))
index={x['path']:x for x in base['files']}
for row in spec['files']:
 name=Path(row['target']).name;assert index[row['target']]==row['before']
 before=read(D/'preimages'/name,row['before']).decode();after=read(D/row['source']['path'],row['source']).decode()
 value=before
 for op in row['operations']:
  assert value.count(op['before'])==op['count'];value=value.replace(op['before'],op['after'])
 assert value==after
 for op in reversed(row['operations']):
  assert value.count(op['after'])==op['count'];value=value.replace(op['after'],op['before'])
 assert value==before
# The actual snapshot reader, age/floor/power policy and native allocator remain unmodified.
read(Path(spec['unchangedObservation']['path']),spec['unchangedObservation'])
owner=(D/'Runtime/Gemma4MTPAuxiliaryOwner.swift').read_text()
assert 'else { os = try QwenResidentResourceEnvironment.observe() }' in owner
assert owner.count('observation.read(for:.owner,deadline:deadline,observationTiming:nil)')==1
for name in ['Gemma4RemoteMTPAssistantRuntime.swift','Gemma4MTPPullAssistant.swift']:
 s=(D/'Runtime'/name).read_text();assert s.count('defer { observation.close() }')==1
assert 'try native.check(); try check(observation)' in (D/'Runtime/Gemma4MTPPullAssistant.swift').read_text()
assert 'try auxiliary.checkStandalone(observation:observation); try native.check()' in (D/'Runtime/Gemma4MTPPullAssistant.swift').read_text()
print(json.dumps(dict(status='source-checked',overlays=5,baseSources=len(index),workspaceMutated=False,fixtureExecuted=False)))
