"""Same-policy paired synthetic comparisons; ordinary routing, no TPS claims."""
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

REPO=Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER=REPO/'experiments/cluster'
BUNDLE=CLUSTER/'inference/.build/arm64-apple-macosx/release'
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
receipt=dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
             driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             synthetic_only=True,performance_qualification=False,executions=[],comparisons=[])

def save(): (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')

def run(profile,dtype,seed,precision,plan):
    name=f'{profile}-{dtype}-seed{seed}-{precision}-'+(plan or 'solo')
    spec=dict(schema_version=1,backend='loopback-test' if plan else 'solo',
        ranks=[dict(location='local')]*(2 if plan else 1),partition=plan or 'ffn',
        capture_logits=True,timeout_seconds=60,
        workload=dict(synthetic=True,synthetic_profile=profile,synthetic_dtype=dtype,
            attention_output_precision=precision,prompt_tokens=65,chunk_size=32,decode_tokens=8,
            warmups=0,repeats=1,seed=seed,teacher_tokens=[12,25,38,51,64,77,90]))
    specfile=OUT/(name+'.spec.json');specfile.write_text(json.dumps(spec,indent=2)+'\n')
    with (OUT/(name+'.stdout')).open('w') as stdout,(OUT/(name+'.stderr')).open('w') as stderr:
        r=subprocess.run([sys.executable,str(CLUSTER/'run_inference.py'),'--spec',str(specfile),
            '--bundle',str(BUNDLE),'--output',str(OUT/name)],stdout=stdout,stderr=stderr,timeout=70)
    data=json.loads((OUT/name/'run.json').read_text())
    record=dict(name=name,exit_code=r.returncode,verified_execution=data.get('verified_execution'),
        bundle_manifest_sha256=data.get('bundle_manifest_sha256'),
        hardware_throughput_candidate=data.get('hardware_throughput_candidate'))
    receipt['executions'].append(record);save();print(name,'exit',r.returncode,flush=True)
    assert r.returncode==0 and record['verified_execution'] and not record['hardware_throughput_candidate'],name
    for report in data['reports']:
        assert report['attentionOutputPrecision']==precision and report['schemaVersion']==5
        assert 'routingReplayEnabled' not in report and 'routingTraceEnabled' not in report
    return name,data['reports']

def compare(name_a,reports_a,name_b,reports_b,same_policy):
    ref=json.loads((OUT/name_a/'rank-0/logits.json').read_text())
    for rank,report in enumerate(reports_b):
        for field in ['configurationSHA256','promptSHA256','teacherSHA256','syntheticProfile','syntheticDType']:
            assert report[field]==reports_a[0][field],field
        if same_policy:assert report['attentionOutputPrecision']==reports_a[0]['attentionOutputPrecision']
        assert report['runs'][0]['decodeInputTokens']==reports_a[0]['runs'][0]['decodeInputTokens']
        values=json.loads((OUT/name_b/f'rank-{rank}/logits.json').read_text())
        rows=[]
        for index,(a,b) in enumerate(zip(ref,values,strict=True)):
            assert len(a)==len(b)==512 and all(math.isfinite(x) for x in a+b)
            rows.append(dict(row=index,max_absolute=max(abs(x-y) for x,y in zip(a,b)),
                relative_rms=math.sqrt(math.fsum((x-y)**2 for x,y in zip(a,b))/math.fsum(x*x for x in a)),
                argmax_equal=max(range(512),key=a.__getitem__)==max(range(512),key=b.__getitem__)))
        record=dict(reference=name_a,candidate=name_b,rank=rank,same_numerical_policy=same_policy,
            rows=rows,observed_only=reports_a[0]['syntheticDType']=='bfloat16')
        if reports_a[0]['syntheticDType']=='float32':
            record['passed']=all(x['max_absolute']<1e-3 and x['relative_rms']<1e-4 and x['argmax_equal'] for x in rows)
            assert record['passed'],record
        receipt['comparisons'].append(record);save()
        print(name_b,'rank',rank,'samepolicy',same_policy,'maxRMS',max(x['relative_rms'] for x in rows),
              'maxabs',max(x['max_absolute'] for x in rows),flush=True)

groups=[('qwen-moe','bfloat16',seed,['native','float32']) for seed in [7,31,103]]
groups += [('qwen27-heads','bfloat16',7,['native','float32']),('qwen-moe','float32',7,['float32'])]
for profile,dtype,seed,policies in groups:
    baselines=[]
    for precision in policies:
        solo,sr=run(profile,dtype,seed,precision,None)
        full,fr=run(profile,dtype,seed,precision,'full')
        compare(solo,sr,full,fr,True)
        baselines.append((solo,sr))
        if dtype=='bfloat16' and profile=='qwen-moe' and seed==7 and precision=='native':
            previous=Path('/Users/developer/DarkbloomDev/cluster-research/runs/qwen-moe-routing-replay-20260913')
            for current,old in [(solo,'solo-ordinary'),(full,'full-ordinary')]:
                assert json.loads((OUT/current/'rank-0/logits.json').read_text())==json.loads((previous/old/'rank-0/logits.json').read_text())
            receipt['native_regression_logits_exact']=True;save()
    if len(baselines)==2:compare(*baselines[0],*baselines[1],False)
print('Evidence:',OUT/'receipt.json',flush=True)
