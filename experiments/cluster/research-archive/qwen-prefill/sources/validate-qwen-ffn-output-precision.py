"""Dense Qwen FFN output precision: paired controls and policy departure."""
import hashlib,json,math,shutil,subprocess,sys
from pathlib import Path
REPO=Path('/Users/developer/DarkbloomDev/d-inference');CLUSTER=REPO/'experiments/cluster'
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
stage=sys.argv[2] if len(sys.argv)>2 else 'full'
assert stage in ('smoke','full')
smoke=stage=='smoke';long_context=stage=='long'
source=CLUSTER/'inference/.build/arm64-apple-macosx/release';BUNDLE=OUT/'bundle';BUNDLE.mkdir()
for p in [source/'cluster-inference',source/'mlx.metallib',*source.glob('*.bundle')]:
    if p.is_dir():shutil.copytree(p,BUNDLE/p.name)
    else:shutil.copy2(p,BUNDLE/p.name)
files={str(p.relative_to(BUNDLE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(BUNDLE.rglob('*')) if p.is_file()}
r=dict(binary_sha256=files['cluster-inference'],bundle_files=files,driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    synthetic_only=True,performance_qualification=False,executions=[],comparisons=[],policy_departures=[],native_regressions=[])
manifest=[]
for name in sorted(subprocess.check_output(['rg','--files','experiments/cluster'],cwd=REPO,text=True).splitlines()):
    p=REPO/name;target=OUT/'source'/p.relative_to(CLUSTER);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
    manifest.append(dict(path=name,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
p=OUT/'source-manifest.json';p.write_text(json.dumps(manifest,indent=2)+'\n');r['source_manifest_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
shutil.copy2(Path(__file__),OUT/Path(__file__).name)
def save():(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
def run(case,dtype,policy,partition):
    profile,seed,prompt,chunk=case
    path="cbv2-contiguous"
    attention,ffn={"native":("native","native"),"attention":("float32","native"),"ffn":("native","float32"),"both":("float32","float32")}[policy]
    distributed=partition!='solo';name=f'{profile}-{dtype}-seed{seed}-prompt{len(prompt)}-{policy}-{partition}'
    spec=dict(schema_version=1,backend='loopback-test' if distributed else 'solo',partition='ffn' if not distributed else partition,
        ranks=[dict(location='local')]*(2 if distributed else 1),timeout_seconds=70,capture_logits=True,
        workload=dict(synthetic=True,synthetic_profile=profile,synthetic_dtype=dtype,seed=seed,execution_path=path,
            prompt_ids=prompt,prompt_tokens=len(prompt),chunk_size=chunk,decode_tokens=8,
            attention_output_precision=attention,ffn_output_precision=ffn,
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
        assert report['schemaVersion']==9 and report['executionPath']==path and report['modelFamily']=='qwen35' and report['feedForwardKind']=='dense' and report['ffnOutputPrecision']==ffn and report['attentionOutputPrecision']==attention
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

def normal(count,seed): return [3+(i*17+seed)%509 for i in range(count)]
cases=[('tiny',7,[3+(i*13+31)%509 for i in range(37)],16)] if smoke else [
 ('tiny',7,normal(65,7),32),('tiny',7,[3+(i*13+31)%509 for i in range(37)],16),
 ('qwen27-heads',7,normal(65,7),32),('qwen27-heads',31,normal(96,31),32),
 ('qwen27-heads',101,normal(129,101),32),('qwen27-heads',503,normal(193,503),32)]
for case in cases:
 values={}
 for policy in ['native','attention','ffn','both']:
  for partition in ['solo','ffn','full']:
   values[policy,partition]=run(case,'bfloat16',policy,partition)
   identity=dict(profile=case[0],seed=case[1],prompt_tokens=len(case[2]),dtype='bfloat16',policy=policy,partition=partition)
   if partition!='solo':
    c=compare(values[policy,'solo'],values[policy,partition]);r['comparisons'].append(dict(**identity,**c))
    print('TP parity',identity,'rms',max(x['relative_rms'] for x in c['rows']),'passed',c['passed'],flush=True)
   if policy!='native':
    c=compare(values['native',partition],values[policy,partition]);r['policy_departures'].append(dict(**identity,**c))
   elif len(case[2])==65 and case[1]==7:
    previous=REPO.parent/'cluster-research/runs/cbv2-inference-20260913'/f'{case[0]}-bfloat16-seed7-cbv2-contiguous-{partition}'/'rank-0/logits.json'
    c=compare(json.loads(previous.read_text()),values[policy,partition]);assert c['exact'],'Native arithmetic regression'
    r['native_regressions'].append(dict(**identity,**c))
   save()
if not smoke:
 case=('qwen27-heads',7,normal(65,7),32);values={}
 for policy in ['native','both']:
  for partition in ['solo','ffn','full']:
   values[policy,partition]=run(case,'float32',policy,partition)
   if partition!='solo':
    c=compare(values[policy,'solo'],values[policy,partition]);r['comparisons'].append(dict(profile=case[0],seed=7,prompt_tokens=65,dtype='float32',policy=policy,partition=partition,**c))
   save()
print('Evidence:',OUT/'receipt.json',flush=True)
