#!/usr/bin/env python3
"""Check exact source union, or root-apply it with preserved original preimages."""
import argparse,hashlib,json,os
from pathlib import Path
ROOT=Path(__file__).resolve().parent
PREFIX='libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'
def read(p):
 p=Path(p)
 if not p.is_file() or p.is_symlink():raise ValueError('Source missing or linked: '+str(p))
 return p.read_bytes()
def sha(b):return hashlib.sha256(b).hexdigest()
def pin(p):
 b=read(p);return dict(path=str(p),bytes=len(b),sha256=sha(b))
def checked(row):
 if pin(row['path'])!=row:raise ValueError('Source pin differs: '+row['path'])
 return read(row['path'])
def save(p,obj):
 p.parent.mkdir(parents=True,exist_ok=True)
 with p.open('x') as f:json.dump(obj,f,indent=2);f.write('\n')
def verify():
 manifest=json.loads(read(ROOT/'source-inputs.json'))
 for r in manifest['members']:checked(dict(r,path=str(ROOT/r['path'])))
 spec=json.loads(read(ROOT/'integration.json'));base=json.loads(checked(spec['baseSources']))
 old={r['path']:r for r in base['files']};assert len(old)==124
 for ref in spec['dependencies'].values():
  root=Path(ref['path']).parent
  for r in json.loads(checked(ref))['members']:checked(dict(r,path=str(root/r['path'])))
 expected=json.loads(checked(spec['expectedSources']))['files'];projection=dict(old)
 transforms={r['target']:r['steps'] for r in json.loads(read(ROOT/'transforms.json'))['files']}
 for row in spec['changes']:
  rel=row['target'];assert rel.startswith(PREFIX) and old.get(rel)==row['before']
  output=checked(row['source']);projection[rel]=dict(path=rel,bytes=len(output),sha256=sha(output))
  if row['before'] is None:continue
  prior=read(ROOT/'Original'/Path(rel).name);assert (len(prior),sha(prior))==(row['before']['bytes'],row['before']['sha256'])
  value=prior.decode()
  for step in transforms[rel]:
   assert value.count(step['before'])==1;value=value.replace(step['before'],step['after'])
  assert value.encode()==output
  for step in reversed(transforms[rel]):
   assert value.count(step['after'])==1;value=value.replace(step['after'],step['before'])
  assert value.encode()==prior
 assert len(expected)==126 and [projection[k] for k in sorted(projection)]==expected
 assert len(spec['changes'])==12 and spec['refillIncluded'] is False
 ledger=read(ROOT/'Runtime/AsyncMTPProposalLedger.swift').decode()
 assert 'return min(maximumProducerGrantTokens, maximumBufferedProposals - branch.proposals.count,\n                   ceiling - branch.highestProducedPosition)' in ledger
 return spec,base,expected

def main():
 p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--apply',action='store_true');p.add_argument('--output',type=Path);a=p.parse_args()
 spec,base,expected=verify()
 if not a.apply:
  assert a.output is None;print(json.dumps(dict(sourceChecksPassed=True,sources=126,overlays=10,additions=2,compilerExecuted=False,nativeExecuted=False)));return
 out=a.output;assert out is not None and out.is_absolute() and out.parent.resolve()==out.parent and not out.exists()
 work=Path(spec['workspace']);assert work.resolve()==work
 # Exact declared source closure only: no artifact/dependency/cache scan.
 for r in base['files']:
  data=read(work/r['path']);assert (len(data),sha(data))==(r['bytes'],r['sha256']),r['path']
 for row in spec['changes']:
  if row['before'] is None:assert not (work/row['target']).exists()
  assert not (work/row['target']).with_name(Path(row['target']).name+'.policy-union-tmp').exists()
 out.mkdir(mode=0o700);save(out/'before.json',base)
 # Preserve every original changed file before the first active source edit.
 for row in spec['changes']:
  if row['before'] is not None:
   dest=out/'preimages'/row['target'];dest.parent.mkdir(parents=True,exist_ok=True)
   with dest.open('xb') as f:f.write(read(work/row['target']))
 for row in spec['changes']:
  dest=work/row['target'];dest.parent.mkdir(parents=True,exist_ok=True);temp=dest.with_name(dest.name+'.policy-union-tmp')
  with temp.open('xb') as f:f.write(checked(row['source']))
  os.replace(temp,dest)
 for r in expected:
  data=read(work/r['path']);assert (len(data),sha(data))==(r['bytes'],r['sha256']),r['path']
 receipt=dict(base,files=expected,remotePolicyUnionPredecessor=spec['baseSources'],
  remotePolicyUnionManifestSHA256=pin(ROOT/'source-inputs.json')['sha256'],
  remotePolicyUnionIntegrationSHA256=pin(ROOT/'integration.json')['sha256'],
  remotePolicyUnionDependencies=spec['dependencies'],remotePolicyUnionChanges=spec['changes'])
 save(out/'sources.json',receipt);print(json.dumps(dict(sourceApplicationPassed=True,sources=126,receipt=pin(out/'sources.json'),compilerExecuted=False,nativeExecuted=False)))
if __name__=='__main__':main()
