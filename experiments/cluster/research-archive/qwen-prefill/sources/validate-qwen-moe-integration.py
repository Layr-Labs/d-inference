"""Paired synthetic MoE and realistic-head geometry checks; no throughput claims."""
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER = REPO/'experiments/cluster'
BUNDLE = CLUSTER/'inference/.build/arm64-apple-macosx/release'
OUT = Path(sys.argv[1])
receipt = json.loads((OUT/'receipt.json').read_text())
assert receipt['binary_sha256'] == hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest()
receipt.update(executions=[],parity=[])

def save(): (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')

def run(group, profile, dtype, plan, teacher):
    name=group+'-'+(plan or 'solo')
    workload=dict(synthetic=True,synthetic_profile=profile,synthetic_dtype=dtype,
                  prompt_tokens=65,chunk_size=32,decode_tokens=8,warmups=1,repeats=2,seed=7)
    if teacher: workload['teacher_tokens']=[12,25,38,51,64,77,90]
    spec=dict(schema_version=1,backend='loopback-test' if plan else 'solo',
              ranks=[dict(location='local')]*(2 if plan else 1),workload=workload,
              capture_logits=True,timeout_seconds=60)
    if plan: spec['partition']=plan
    specpath=OUT/(name+'.spec.json');specpath.write_text(json.dumps(spec,indent=2)+'\n')
    with (OUT/(name+'.stdout')).open('w') as out,(OUT/(name+'.stderr')).open('w') as err:
        result=subprocess.run([sys.executable,str(CLUSTER/'run_inference.py'),'--spec',str(specpath),
                               '--bundle',str(BUNDLE),'--output',str(OUT/name)],stdout=out,stderr=err,timeout=70)
    data=json.loads((OUT/name/'run.json').read_text())
    receipt['executions'].append(dict(name=name,exit_code=result.returncode,
        verified=data.get('verified_execution',False),bundle_sha256=data.get('bundle_manifest_sha256'),
        hardware_throughput_candidate=data.get('hardware_throughput_candidate',False)))
    save();print(name,'exit',result.returncode,flush=True)
    if result.returncode: raise SystemExit('Execution failed; see '+name)
    return name,data['reports']

groups=[('tiny-f32','tiny','float32',True,['full']),
        ('moe-f32-teacher','qwen-moe','float32',True,['ffn','full']),
        ('moe-f32-greedy','qwen-moe','float32',False,['full']),
        ('moe-bf16-teacher','qwen-moe','bfloat16',True,['full'])]
for profile in ['qwen9-heads','qwen27-heads']:
    for dtype in ['float32','bfloat16']:
        groups.append((profile+'-'+dtype,profile,dtype,True,['full']))
for group,profile,dtype,teacher,plans in groups:
    baseline_name,baseline=run(group,profile,dtype,None,teacher)
    reference=json.loads((OUT/baseline_name/'rank-0/logits.json').read_text())
    assert len(reference)==8
    for plan in plans:
        name,candidates=run(group,profile,dtype,plan,teacher)
        for rank,candidate in enumerate(candidates):
            for field in ['configurationSHA256','promptSHA256','teacherSHA256','syntheticProfile',
                          'syntheticDType','feedForwardKind','embeddingActivationDType','ffnScaleDTypes']:
                assert candidate.get(field)==baseline[0].get(field),field
            values=json.loads((OUT/name/f'rank-{rank}/logits.json').read_text())
            rows=[]
            for index,(left,right) in enumerate(zip(reference,values,strict=True)):
                assert len(left)==len(right)==512 and all(type(x) in (float,int) and math.isfinite(x) for x in left+right)
                differences=[a-b for a,b in zip(left,right,strict=True)]
                choices=sorted(range(len(left)),key=left.__getitem__,reverse=True)
                rows.append(dict(row=index,max_absolute=max(map(abs,differences)),
                    relative_rms=math.sqrt(math.fsum(x*x for x in differences)/math.fsum(x*x for x in left)),
                    argmax_equal=choices[0]==max(range(len(right)),key=right.__getitem__),
                    reference_top_two_margin=left[choices[0]]-left[choices[1]],
                    histories_equal=baseline[0]['runs'][-1]['decodeInputTokens'][:index]==candidate['runs'][-1]['decodeInputTokens'][:index]))
            token_agreement=[a['generatedTokens']==b['generatedTokens'] for a,b in zip(baseline[0]['runs'],candidate['runs'],strict=True)]
            record=dict(group=group,partition=plan,rank=rank,rows=rows,observed_only=dtype=='bfloat16',
                        baseline_token_agreement_by_repetition=token_agreement,
                        local_argmax_disagreements=[r['localArgmaxDisagreementCount'] for r in candidate['runs']])
            if dtype=='float32':
                record['passed']=all(token_agreement) and all(r['max_absolute']<1e-3 and r['relative_rms']<1e-4 and r['histories_equal'] for r in rows)
            receipt['parity'].append(record);save()
            print(group,plan,'rank',rank,'max',max(r['max_absolute'] for r in rows),
                  'rms',max(r['relative_rms'] for r in rows),'tokens',token_agreement,flush=True)
            if record.get('passed') is False:raise SystemExit('F32 model parity failed')
print('Evidence:',OUT/'receipt.json',flush=True)
