"""Bounded synthetic router diagnostics using the normal rank supervisors."""
import hashlib
import json
from pathlib import Path
import sys
import uuid

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER = REPO / 'experiments/cluster'
sys.path.insert(0, str(CLUSTER))
from runtime.bundle import snapshot
from runtime.configuration import loopback_addresses, validate
from runtime.processes import run_cohort, stage
from runtime.reports import read_report, reports

OUT = Path(sys.argv[1])
OUT.mkdir(mode=0o700, parents=True, exist_ok=False)
BUNDLE = CLUSTER / 'inference/.build/arm64-apple-macosx/release'
receipt = dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
               driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               synthetic_only=True, performance_measurements_valid=False, executions=[])

def save():
    (OUT/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')

for dtype in ['float32', 'bfloat16']:
    for plan in [None, 'ffn', 'full']:
        name = dtype + '-' + (plan or 'solo')
        output = OUT / name
        output.mkdir(mode=0o700)
        spec = validate(dict(schema_version=1, backend='loopback-test' if plan else 'solo',
            ranks=[dict(location='local')] * (2 if plan else 1), capture_logits=True,
            partition=plan or 'ffn', timeout_seconds=60,
            workload=dict(synthetic=True, synthetic_profile='qwen-moe', synthetic_dtype=dtype,
                          prompt_tokens=65, chunk_size=32, decode_tokens=8, warmups=0, repeats=1,
                          seed=7, teacher_tokens=[12,25,38,51,64,77,90])))
        digest = snapshot(BUNDLE, output/'bundle')
        hostfile = loopback_addresses() if plan else None
        run_id = uuid.uuid4().hex
        ranks=[]
        for rank in range(len(spec['ranks'])):
            item=stage(spec,rank,output,digest,hostfile,run_id)
            configpath=Path(item['local'])/'rank.json'
            config=json.loads(configpath.read_text())
            config['arguments'] += ['--routing-file','@rank/routing.json']
            configpath.write_text(json.dumps(config,indent=2)+'\n')
            ranks.append(item)
        record=dict(name=name,spec=spec,bundle_manifest_sha256=digest,ranks=ranks)
        (output/'run.json').write_text(json.dumps(record,indent=2)+'\n')
        record.update(run_cohort(ranks,65))
        if not all(code==0 for code in record['exit_codes']):
            (output/'run.json').write_text(json.dumps(record,indent=2)+'\n')
            receipt['executions'].append(record); save()
            raise SystemExit(f'Routing diagnostic failed: {name}')
        record['reports']=[read_report(Path(r['local'])/'stdout.jsonl') for r in ranks]
        for rank,report in zip(ranks,record['reports'],strict=True):
            assert report['routingTraceEnabled'] is True and report['correctnessOnly'] is True
            assert report['throughputMeasurementValid'] is False
            assert report['syntheticWeights'] is True
            assert len(report['runs'])==1 and report['runs'][0]['decodeInputTokens']==[12,25,38,51,64,77,90]
            for filename in ['routing.json','logits.json']:
                rank[filename+'_sha256']=hashlib.sha256((Path(rank['local'])/filename).read_bytes()).hexdigest()
        record['diagnostic_execution_verified']=True
        control=OUT/(name+'-untraced')
        control.mkdir(mode=0o700)
        (control/'bundle').symlink_to(output/'bundle',target_is_directory=True)
        control_hostfile=loopback_addresses() if plan else None
        control_ranks=[stage(spec,index,control,digest,control_hostfile,uuid.uuid4().hex)
                       for index in range(len(spec['ranks']))]
        control_result=run_cohort(control_ranks,65)
        assert all(code==0 for code in control_result['exit_codes']), control_result
        control_result['reports']=reports(control_ranks,spec)
        exact=[]
        for rank in range(len(ranks)):
            traced=json.loads((output/f'rank-{rank}/logits.json').read_text())
            untraced=json.loads((control/f'rank-{rank}/logits.json').read_text())
            exact.append(traced==untraced)
        control_result['traced_logits_exactly_equal_by_rank']=exact
        control_result['bundle_manifest_sha256']=digest
        (control/'run.json').write_text(json.dumps(control_result,indent=2)+'\n')
        record['untraced_control']=control_result
        assert all(exact), f'Instrumentation changed output: {name}'
        (output/'run.json').write_text(json.dumps(record,indent=2)+'\n')
        receipt['executions'].append(dict(name=name,bundle_manifest_sha256=digest,
                                        exit_codes=record['exit_codes'],diagnostic_execution_verified=True,
                                        untraced_control_logits_equal=exact))
        save();print(name,record['exit_codes'],flush=True)
print('Routing evidence:', OUT, flush=True)
