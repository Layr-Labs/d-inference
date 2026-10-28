"""Controlled baseline-router-logit substitution; no inference qualification."""
import hashlib
import json
import math
from pathlib import Path
import sys
import uuid

REPO=Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER=REPO/'experiments/cluster'
sys.path.insert(0,str(CLUSTER))
from runtime.bundle import snapshot
from runtime.configuration import loopback_addresses, validate
from runtime.processes import run_cohort, stage
from runtime.reports import read_report, reports

SOURCE=Path(sys.argv[1]); OUT=Path(sys.argv[2])
OUT.mkdir(parents=True,mode=0o700,exist_ok=False)
BUNDLE=CLUSTER/'inference/.build/arm64-apple-macosx/release'
reference=SOURCE/'bfloat16-solo/rank-0/routing.json'
receipt=dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
             driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             reference_trace_sha256=hashlib.sha256(reference.read_bytes()).hexdigest(),
             reference_capture_binary_sha256=json.loads((SOURCE/'receipt.json').read_text())['binary_sha256'],
             deliberately_overridden_routing=True, numerical_qualification=False, executions=[])

def save(): (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')

def run(name,plan,replay_reference=None,expect_failure=False):
    output=OUT/name;output.mkdir(mode=0o700)
    spec=validate(dict(schema_version=1,backend='loopback-test' if plan else 'solo',
        ranks=[dict(location='local')]*(2 if plan else 1),capture_logits=True,
        partition=plan or 'ffn',timeout_seconds=60,
        workload=dict(synthetic=True,synthetic_profile='qwen-moe',synthetic_dtype='bfloat16',
                      prompt_tokens=65,chunk_size=32,decode_tokens=8,warmups=0,repeats=1,
                      seed=7,teacher_tokens=[12,25,38,51,64,77,90])))
    digest=snapshot(BUNDLE,output/'bundle')
    hosts=loopback_addresses() if plan else None
    ranks=[stage(spec,index,output,digest,hosts,uuid.uuid4().hex) for index in range(len(spec['ranks']))]
    if replay_reference:
        for rank in ranks:
            path=Path(rank['local'])/'rank.json';config=json.loads(path.read_text())
            config['arguments']+=['--routing-replay-file',str(replay_reference)]
            path.write_text(json.dumps(config,indent=2)+'\n')
    record=dict(name=name,spec=spec,bundle_manifest_sha256=digest,ranks=ranks)
    record.update(run_cohort(ranks,65))
    if expect_failure:
        assert record['exit_codes']==[1],record
        assert not (output/'rank-0/logits.json').exists()
        record['rejected']=True
        record['reason']=(output/'rank-0/stderr.log').read_text().splitlines()[-1]
    else:
        assert all(code==0 for code in record['exit_codes']),record
        record['reports']=[read_report(Path(rank['local'])/'stdout.jsonl') for rank in ranks]
        if replay_reference:
            for report in record['reports']:
                assert report['routingReplayEnabled'] is True
                assert report['correctnessOnly'] is True and report['throughputMeasurementValid'] is False
                assert report['runs'][0]['decodeInputTokens']==[12,25,38,51,64,77,90]
        else:
            reports(ranks,spec)
        for rank in ranks:
            rank['logits_sha256']=hashlib.sha256((Path(rank['local'])/'logits.json').read_bytes()).hexdigest()
    (output/'run.json').write_text(json.dumps(record,indent=2)+'\n')
    receipt['executions'].append(dict(name=name,exit_codes=record['exit_codes'],
                                    bundle_manifest_sha256=digest,rejected=expect_failure))
    save();print(name,record['exit_codes'],flush=True)
    return record

for plan in [None,'full']:
    label=plan or 'solo'
    run(label+'-ordinary',plan)
    run(label+'-reference-routing',plan,reference)
    previous=json.loads((SOURCE/f'bfloat16-{label}/rank-0/logits.json').read_text())
    ordinary=json.loads((OUT/f'{label}-ordinary/rank-0/logits.json').read_text())
    assert ordinary==previous,f'Current ordinary build changed {label} logits'

baseline=json.loads((OUT/'solo-ordinary/rank-0/logits.json').read_text())
receipt['comparisons']=[]
for label in ['solo-reference-routing','full-ordinary','full-reference-routing']:
    for rank in range(1 if label.startswith('solo') else 2):
        values=json.loads((OUT/label/f'rank-{rank}/logits.json').read_text())
        rows=[]
        for i,(a,b) in enumerate(zip(baseline,values,strict=True)):
            assert len(a)==len(b)==512 and all(math.isfinite(x) for x in a+b)
            rows.append(dict(row=i,max_absolute=max(abs(x-y) for x,y in zip(a,b)),
                relative_rms=math.sqrt(math.fsum((x-y)**2 for x,y in zip(a,b))/math.fsum(x*x for x in a)),
                exactly_equal=a==b))
        receipt['comparisons'].append(dict(name=label,rank=rank,rows=rows))
        print(label,rank,'max RMS',max(r['relative_rms'] for r in rows),'max abs',max(r['max_absolute'] for r in rows),flush=True)
        if label.startswith('solo'): assert values==baseline,'Reference replay did not reproduce baseline'
for kind in ['identity','logits-hash']:
    malformed=json.loads(reference.read_text())
    if kind=='identity':malformed['identity']['promptSHA256']='f'*64
    else:malformed['events'][0]['logitSHA256']='f'*64
    path=OUT/(kind+'-mismatch.json');path.write_text(json.dumps(malformed))
    run('reject-'+kind,None,path,expect_failure=True)
save();print('Causal diagnostic:',OUT/'receipt.json',flush=True)
