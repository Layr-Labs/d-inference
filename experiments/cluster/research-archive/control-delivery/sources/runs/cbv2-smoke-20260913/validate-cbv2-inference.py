"""Actual CBv2 model/state path against ordinary and two-rank dense partitions."""
import hashlib,json,math,shutil,subprocess,sys
from pathlib import Path
REPO=Path('/Users/developer/DarkbloomDev/d-inference');CLUSTER=REPO/'experiments/cluster'
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
smoke=len(sys.argv)>2 and sys.argv[2]=='smoke'
source=CLUSTER/'inference/.build/arm64-apple-macosx/release';BUNDLE=OUT/'bundle';BUNDLE.mkdir()
for p in [source/'cluster-inference',source/'mlx.metallib',*source.glob('*.bundle')]:
    if p.is_dir():shutil.copytree(p,BUNDLE/p.name)
    else:shutil.copy2(p,BUNDLE/p.name)
files={str(p.relative_to(BUNDLE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(BUNDLE.rglob('*')) if p.is_file()}
r=dict(binary_sha256=files['cluster-inference'],bundle_files=files,driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    synthetic_only=True,performance_qualification=False,executions=[],comparisons=[],path_comparisons=[])
manifest=[]
for name in sorted(subprocess.check_output(['rg','--files','experiments/cluster'],cwd=REPO,text=True).splitlines()):
    p=REPO/name;target=OUT/'source'/p.relative_to(CLUSTER);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
    manifest.append(dict(path=name,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
p=OUT/'source-manifest.json';p.write_text(json.dumps(manifest,indent=2)+'\n');r['source_manifest_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
shutil.copy2(Path(__file__),OUT/Path(__file__).name)
def save():(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
def run(profile,dtype,seed,path,partition):
    distributed=partition!='solo';name=f'{profile}-{dtype}-seed{seed}-{path}-{partition}'
    spec=dict(schema_version=1,backend='loopback-test' if distributed else 'solo',partition='ffn' if not distributed else partition,
        ranks=[dict(location='local')]*(2 if distributed else 1),timeout_seconds=70,capture_logits=True,
        workload=dict(synthetic=True,synthetic_profile=profile,synthetic_dtype=dtype,seed=seed,execution_path=path,
            prompt_tokens=65 if seed==7 else 97,chunk_size=32 if seed==7 else 16,decode_tokens=8,
            teacher_tokens=[12,25,38,51,64,77,90],repeats=1,warmups=0))
    p=OUT/(name+'.spec.json');p.write_text(json.dumps(spec,indent=2)+'\n')
    with (OUT/(name+'.stdout')).open('w') as out,(OUT/(name+'.stderr')).open('w') as err:
        result=subprocess.run([sys.executable,str(CLUSTER/'run_inference.py'),'--spec',str(p),'--bundle',str(BUNDLE),'--output',str(OUT/name)],
            stdout=out,stderr=err,timeout=85)
    record=json.loads((OUT/name/'run.json').read_text())
    entry=dict(name=name,exit_code=result.returncode,verified_execution=record.get('verified_execution'),bundle_manifest_sha256=record.get('bundle_manifest_sha256'))
    r['executions'].append(entry);save()
    assert result.returncode==0 and record['verified_execution'] and not record['hardware_throughput_candidate'],name
    outputs=[]
    for i,report in enumerate(record['reports']):
        assert report['schemaVersion']==8 and report['executionPath']==path and report['modelFamily']=='qwen35' and report['feedForwardKind']=='dense'
        assert report['runs'][0]['decodeInputTokens']==[12,25,38,51,64,77,90]
        outputs.append(json.loads((OUT/name/f'rank-{i}/logits.json').read_text()))
    assert all(x==outputs[0] for x in outputs),'Rank logits diverged'
    print(name,'execution passed',flush=True)
    return outputs[0]
def compare(a,b):
    assert len(a)==len(b)==8
    result=[]
    for i,(x,y) in enumerate(zip(a,b,strict=True)):
        assert len(x)==len(y)==512 and all(math.isfinite(v) for v in x+y)
        result.append(dict(row=i,max_absolute=max(abs(u-v) for u,v in zip(x,y)),
            relative_rms=math.sqrt(math.fsum((u-v)**2 for u,v in zip(x,y))/math.fsum(u*u for u in x)),
            argmax_equal=max(range(512),key=x.__getitem__)==max(range(512),key=y.__getitem__)))
    return dict(rows=result,exact=a==b,passed=all(v['max_absolute']<1e-3 and v['relative_rms']<1e-4 and v['argmax_equal'] for v in result))
for profile in (['tiny'] if smoke else ['tiny','qwen9-heads','qwen27-heads']):
 for dtype in (['float32'] if smoke else ['float32','bfloat16']):
  for seed in ([7] if smoke else [7,31]):
   values={}
   for path in ['ordinary','cbv2-contiguous']:
    for partition in ['solo','ffn','full']:
     values[path,partition]=run(profile,dtype,seed,path,partition)
     if partition!='solo':
      c=compare(values[path,'solo'],values[path,partition]);r['comparisons'].append(dict(profile=profile,dtype=dtype,seed=seed,path=path,partition=partition,**c))
      print('paired',path,partition,'maxRMS',max(x['relative_rms'] for x in c['rows']),'passed',c['passed'],flush=True);save()
   for partition in ['solo','ffn','full']:
    c=compare(values['ordinary',partition],values['cbv2-contiguous',partition]);r['path_comparisons'].append(dict(profile=profile,dtype=dtype,seed=seed,partition=partition,**c))
    print('path parity',partition,'maxRMS',max(x['relative_rms'] for x in c['rows']),'passed',c['passed'],flush=True)
   save()
print('Evidence:',OUT/'receipt.json',flush=True)
