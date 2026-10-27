"""Create-only refill-only harness; actual new build remains a required late binding."""
import argparse,ast,hashlib,importlib.util,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
B=ROOT.parent/'decode-faster-than-solo-20260920'
OUTPUTS={k:B/n for k,n in dict(local='harness-local-mtp-single-refill-v1',remote='harness-remote-mtp-single-refill-v1',numerical='remote-mtp-single-refill-numerical-v1').items()}

def read(path):
 p=Path(path);assert p.is_absolute() and p.parent.resolve()==p.parent
 assert p.is_file() and not p.is_symlink() and p.stat().st_size<=2*1024**2,p
 return p.read_bytes()
def sha(raw):return hashlib.sha256(raw).hexdigest()
def encode(value):return (json.dumps(value,indent=2,allow_nan=False)+'\n').encode()
def pin(path):
 raw=read(path);return dict(path=str(path),bytes=len(raw),sha256=sha(raw))
def pinned(row):
 raw=read(row['path']);assert (len(raw),sha(raw))==(row['bytes'],row['sha256']),row['path'];return raw
def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def members(path):
 doc=json.loads(read(path));base=Path(path).parent
 for row in doc['members']:pinned(dict(row,path=str(base/row['path'])))
 return doc

def verify():
 members(ROOT/'source-inputs.json');spec=json.loads(read(ROOT/'bindings.json'))
 for row in spec['authorities']:pinned(row)
 parent=module('refill_v3_parent',Path(spec['parent']['path']).parent/'prepare.py')
 old,projects,description,base_expected=parent.verify()
 rebase=module('refill_rebase',Path(spec['refill']['rebaseManifest']['path']).parent/'check_sources.py');rebase.main()
 union=json.loads(pinned(spec['refill']['integration']));base=json.loads(pinned(union['baseSources']))
 assert base['files']==base_expected and len(base_expected)==122
 expected=json.loads(pinned(spec['refill']['expectedSources']))['files'];assert len(expected)==123
 for kind in ('local','remote'):
  before='gemma4-'+kind+'-mtp-o128-20260920-v3';after='gemma4-'+kind+'-mtp-single-refill-20260920-v1'
  for name,raw in list(projects[kind].items()):
   if name.endswith('.py'):projects[kind][name]=raw.replace(before.encode(),after.encode())
 for row in spec['overlays']:
  before=projects[row['kind']].get(row['path'])
  assert (None if before is None else dict(bytes=len(before),sha256=sha(before)))==row['before'],row['path']
  after=read(ROOT/row['source']);assert dict(bytes=len(after),sha256=sha(after))==row['after']
  projects[row['kind']][row['path']]=after
 for kind,files in projects.items():
  for name,raw in files.items():
   if name.endswith('.py'):
    ast.parse(raw,name)
    if kind in ('local','remote'):assert b'mtp-o128-20260920-v' not in raw,name
 assert projects['local']['numerical_compare.py']==projects['numerical']['numeric_reader.py']
 assert projects['remote']['package/refill_contract.py']==projects['numerical']['refill_contract.py']
 return spec,projects,parent,old,description,union,expected

def source_fields(spec,union):
 return dict(remoteRefillPredecessor=union['baseSources'],remoteRefillManifestSHA256=spec['refill']['manifest']['sha256'],
  remoteRefillRebaseManifestSHA256=spec['refill']['rebaseManifest']['sha256'],remoteRefillIntegrationSHA256=spec['refill']['integration']['sha256'])

def bind(build_path,source_path,spec,parent,old,description,union,expected):
 assert str(build_path)==spec['plannedBuild'] and str(source_path)==spec['plannedSources']
 inherited=dict(old,plannedSources=spec['plannedSources'],plannedBuild=spec['plannedBuild'])
 build,source=parent.bind(build_path,source_path,inherited,description,expected)
 for key,want in source_fields(spec,union).items():assert source[key]==want,key
 return build,source

def prepare(build_path,source_path):
 spec,projects,parent,old,description,union,expected=verify()
 build,source=bind(build_path,source_path,spec,parent,old,description,union,expected)
 assert all(not p.exists() and not p.is_symlink() and p.parent.resolve()==p.parent for p in OUTPUTS.values())
 for kind in ('local','remote'):
  required=json.loads(projects[kind]['required-native-sources.json']);parent.bind_resources(build['resources'],required['resources'])
  if kind=='remote':required['packedHeadFiles']=required['requiredFiles']
  required.update(requiredFiles=expected,actualBuildReceipt=pin(build_path),actualSources=pin(source_path),
   nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'],
   remoteControlSourceManifestSHA256=old['control']['manifest']['sha256'],remoteControlIntegrationSHA256=old['control']['integration']['sha256'],
   remoteControlBaseSources=old['controlUnion']['baseSources'],remoteMeasurementBaseSources=old['measurementUnion']['baseSources'],
   remoteMeasurementCompositionManifestSHA256=old['measurement']['manifest']['sha256'],remoteMeasurementIntegrationSHA256=old['measurement']['integration']['sha256'],
   outputDescriptionPredecessor=description['baseSources'],outputDescriptionCorrectionManifestSHA256=old['native']['manifest']['sha256'],
   outputDescriptionCorrectionIntegrationSHA256=old['native']['integration']['sha256'],
   **old['controlUnion']['sourceFields'],**old['measurementUnion']['sourceFields'],**source_fields(spec,union))
  projects[kind]['required-native-sources.json']=encode(required)
 provenance=dict(schema='gemma4_single_refill_harness_preparation_v1',draft=pin(ROOT/'source-inputs.json'),parent=spec['parent'],refill=spec['refill'],
  actualBuildReceipt=pin(build_path),actualSources=pin(source_path),outputCounts=[16,128],verificationDepths=[1,2],
  explicitRefillPolicy='single_for_depth_one_v1',explicitRefillDepth=1,snapshotBatchEnabled=False,nativeExecuted=False,compilerExecuted=False,remoteExecuted=False)
 for files in projects.values():files['single-refill-provenance.json']=encode(provenance)
 manifests={k:parent.source_manifest(projects[k]) for k in ('local','remote')}
 numeric=json.loads(projects['numerical']['inputs.json'])
 for kind in ('local','remote'):
  raw=encode(manifests[kind]);numeric[kind+'Harness']=dict(path=str(OUTPUTS[kind]/'source-inputs.json'),bytes=len(raw),sha256=sha(raw))
 candidates=[ROOT/'proposed/numerical',B/'mtp-o128-harness-v3-draft/proposed/numerical',B/'mtp-o128-harness-v2-draft/proposed/numerical',B/'mtp-o128-harness-draft/proposed/numerical',Path(old['bases']['numerical']['path']).parent]
 readers=[]
 for name in ('numeric_reader.py','recorded_math.py','snapshot.py','workload_contract.py','control_contract.py','binding_common.py','timing_contract.py','refill_contract.py'):
  matches=[p/name for p in candidates if (p/name).is_file() and read(p/name)==projects['numerical'][name]];assert matches,name
  readers.append(dict(path=name,source=str(matches[0]),bytes=len(projects['numerical'][name]),sha256=sha(projects['numerical'][name])))
 numeric.update(readers=readers,producerSources=old['producerSources']);projects['numerical']['inputs.json']=encode(numeric)
 manifests['numerical']=parent.source_manifest(projects['numerical'])
 for kind,target in OUTPUTS.items():
  target.mkdir(mode=0o700)
  for name,raw in sorted(projects[kind].items()):
   path=target/name;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
   with path.open('xb') as f:f.write(raw)
  with (target/'source-inputs.json').open('xb') as f:f.write(encode(manifests[kind]))
 print(json.dumps(dict(status='source-prepared',outputs={k:pin(p/'source-inputs.json') for k,p in OUTPUTS.items()},nativeSHA256=build['nativeSHA256'])))

def main():
 p=argparse.ArgumentParser(allow_abbrev=False);g=p.add_mutually_exclusive_group(required=True);g.add_argument('--check',action='store_true');g.add_argument('--prepare',action='store_true')
 p.add_argument('--build-receipt',type=Path);p.add_argument('--sources',type=Path);a=p.parse_args()
 if a.check:
  assert a.build_receipt is None and a.sources is None
  _,projects,_,_,_,_,expected=verify();print(json.dumps(dict(status='source-checked',projects={k:len(v) for k,v in projects.items()},nativeSources=len(expected),testsExecuted=False)))
 else:
  assert a.build_receipt and a.sources;prepare(a.build_receipt,a.sources)
if __name__=='__main__':main()
