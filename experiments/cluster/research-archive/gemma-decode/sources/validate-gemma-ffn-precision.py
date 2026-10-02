"""Paired complete synthetic Gemma forwards; no performance qualification."""
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

REPO=Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER=REPO/'experiments/cluster'
BUNDLE=CLUSTER/'inference/.build/arm64-apple-macosx/release'
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
receipt=dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
    driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),synthetic_only=True,
    performance_qualification=False,executions=[],comparisons=[])
sources=[]
for name in sorted(subprocess.check_output(['rg','--files','experiments/cluster'],cwd=REPO,text=True).splitlines()):
    path=REPO/name;target=OUT/'source'/path.relative_to(CLUSTER)
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
    sources.append(dict(path=name,sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
manifest=OUT/'source-manifest.json';manifest.write_text(json.dumps(sources,indent=2)+'\n')
receipt['source_manifest_sha256']=hashlib.sha256(manifest.read_bytes()).hexdigest()
shutil.copyfile(Path(__file__),OUT/Path(__file__).name)

def save(): (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')

def run(profile,dtype,seed,precision,distributed):
    name=f'{profile}-{dtype}-seed{seed}-{precision}-'+('ffn' if distributed else 'solo')
    spec=dict(schema_version=1,backend='loopback-test' if distributed else 'solo',partition='ffn',
        ranks=[dict(location='local')]*(2 if distributed else 1),timeout_seconds=45,capture_logits=True,
        workload=dict(synthetic=True,synthetic_profile=profile,synthetic_dtype=dtype,seed=seed,ffn_branch_precision=precision,
            prompt_tokens=65 if seed==7 else 97,chunk_size=32 if seed==7 else 16,decode_tokens=8,
            teacher_tokens=[12,25,38,51,64,77,90],repeats=1,warmups=0))
    specfile=OUT/(name+'.spec.json');specfile.write_text(json.dumps(spec,indent=2)+'\n')
    with (OUT/(name+'.stdout')).open('w') as stdout,(OUT/(name+'.stderr')).open('w') as stderr:
        proc=subprocess.run([sys.executable,str(CLUSTER/'run_inference.py'),'--spec',str(specfile),
            '--bundle',str(BUNDLE),'--output',str(OUT/name)],stdout=stdout,stderr=stderr,timeout=55)
    record=json.loads((OUT/name/'run.json').read_text())
    receipt['executions'].append(dict(name=name,exit_code=proc.returncode,
        verified_execution=record.get('verified_execution'),bundle_manifest_sha256=record.get('bundle_manifest_sha256')))
    save();assert proc.returncode==0 and record['verified_execution'] and not record['hardware_throughput_candidate'],name
    for report in record['reports']:
        assert report['schemaVersion']==7 and report['modelFamily']=='gemma4' and report['ffnBranchPrecision']==precision
        assert report['runs'][0]['decodeInputTokens']==[12,25,38,51,64,77,90]
    logits=[json.loads((OUT/name/f'rank-{i}/logits.json').read_text()) for i in range(len(record['reports']))]
    if distributed:
        assert logits[0]==logits[1]
        storage=record['reports'][0]['partitionStorage']
        assert storage==record['reports'][1]['partitionStorage']
        assert storage['ranks'][0]['loadedTensorBytes']!=storage['ranks'][1]['loadedTensorBytes']
        assert record['reports'][0]['parameterLayoutSHA256']!=record['reports'][1]['parameterLayoutSHA256']
    return name,logits[0]

def compare_rows(a,b):
    assert len(a)==len(b)==8
    rows=[]
    for index,(x,y) in enumerate(zip(a,b,strict=True)):
        assert len(x)==len(y)==512 and all(math.isfinite(v) for v in x+y)
        rows.append(dict(row=index,max_absolute=max(abs(u-v) for u,v in zip(x,y)),
            relative_rms=math.sqrt(math.fsum((u-v)**2 for u,v in zip(x,y))/math.fsum(u*u for u in x)),
            argmax_equal=max(range(512),key=x.__getitem__)==max(range(512),key=y.__getitem__)))
    return rows

receipt['policy_departures']=[]
receipt['native_archived_exact']=[]
old=OUT.parent/'gemma-whole-model-20260913'
for profile in ['gemma-moe','gemma-moe-w8']:
    for dtype in ['bfloat16','float32']:
        for seed in ([7,31,101,211] if dtype=='bfloat16' else [7,31]):
            values={}
            for precision in (['native','float32'] if dtype=='bfloat16' else ['float32']):
                solo,a=run(profile,dtype,seed,precision,False)
                tp,b=run(profile,dtype,seed,precision,True)
                rows=compare_rows(a,b)
                passed=all(r['max_absolute']<1e-3 and r['relative_rms']<1e-4 and r['argmax_equal'] for r in rows)
                result=dict(solo=solo,partitioned=tp,precision=precision,dtype=dtype,seed=seed,profile=profile,
                    rows=rows,strict_logit_gate_passed=passed,qualification='synthetic-only')
                receipt['comparisons'].append(result);values[precision]=(a,b)
                if precision=='native' and seed in [7,31]:
                    for mode,logits in [('solo',a),('ffn',b)]:
                        previous=json.loads((old/f'{profile}-{dtype}-seed{seed}-{mode}'/'rank-0/logits.json').read_text())
                        assert logits==previous, 'Native policy changed relative to archived schema6 binary'
                    receipt['native_archived_exact'].append(dict(profile=profile,dtype=dtype,seed=seed))
                print(tp,'maxRMS',max(r['relative_rms'] for r in rows),'argmax',sum(r['argmax_equal'] for r in rows),'/8',flush=True)
                save()
                if dtype=='float32':assert passed,result
            if dtype=='bfloat16':
                receipt['policy_departures'].append(dict(profile=profile,dtype=dtype,seed=seed,
                    solo_rows=compare_rows(values['native'][0],values['float32'][0]),
                    tp_rows=compare_rows(values['native'][1],values['float32'][1])))
            else:
                # F32 input promotion/cast is an identity policy. Check old native F32 controls too.
                for mode,logits in [('solo',values['float32'][0]),('ffn',values['float32'][1])]:
                    previous=json.loads((old/f'{profile}-{dtype}-seed{seed}-{mode}'/'rank-0/logits.json').read_text())
                    assert logits==previous,'F32 identity policy changed values'
            save()
print('Evidence:',OUT/'receipt.json',flush=True)
