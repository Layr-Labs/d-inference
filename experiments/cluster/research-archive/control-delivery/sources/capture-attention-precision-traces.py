"""Precision-bound trace/replay controls through bounded rank supervisors."""
import hashlib,json
from pathlib import Path
import sys,uuid

ROOT=Path('/Users/developer/DarkbloomDev/d-inference');CLUSTER=ROOT/'experiments/cluster'
sys.path.insert(0,str(CLUSTER))
from runtime.bundle import snapshot
from runtime.configuration import validate,loopback_addresses
from runtime.processes import stage,run_cohort
from runtime.reports import read_report

OUT=Path(sys.argv[1]);OUT.mkdir(parents=True,mode=0o700,exist_ok=False)
BUNDLE=CLUSTER/'inference/.build/arm64-apple-macosx/release'
NORMAL=Path('/Users/developer/DarkbloomDev/cluster-research/runs/attention-output-precision-20260913')
receipt=dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
             driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             synthetic_only=True,performance_measurements_valid=False,executions=[],uninstrumented_references={})
for mode in ['solo','full']:
    directory=NORMAL/f'qwen-moe-bfloat16-seed7-float32-{mode}'
    receipt['uninstrumented_references']['wide-'+mode]=dict(directory=str(directory),
        run_sha256=hashlib.sha256((directory/'run.json').read_bytes()).hexdigest(),
        rank_logits_sha256=[hashlib.sha256((directory/f'rank-{rank}/logits.json').read_bytes()).hexdigest() for rank in range(1 if mode=='solo' else 2)])

def save(): (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
def run(name,precision,full=False,trace=False,replay=None,reject=False):
    output=OUT/name;output.mkdir(mode=0o700)
    spec=validate(dict(schema_version=1,backend='loopback-test' if full else 'solo',
        ranks=[dict(location='local')]*(2 if full else 1),capture_logits=True,
        partition='full' if full else 'ffn',timeout_seconds=60,
        workload=dict(synthetic=True,synthetic_dtype='bfloat16',synthetic_profile='qwen-moe',
            attention_output_precision=precision,prompt_tokens=65,chunk_size=32,decode_tokens=8,
            warmups=0,repeats=1,seed=7,teacher_tokens=[12,25,38,51,64,77,90])))
    digest=snapshot(BUNDLE,output/'bundle');hosts=loopback_addresses() if full else None
    ranks=[stage(spec,index,output,digest,hosts,uuid.uuid4().hex) for index in range(len(spec['ranks']))]
    for rank in ranks:
        configpath=Path(rank['local'])/'rank.json';config=json.loads(configpath.read_text())
        if trace:config['arguments']+=['--routing-file','@rank/routing.json']
        if replay:config['arguments']+=['--routing-replay-file',str(replay)]
        configpath.write_text(json.dumps(config,indent=2)+'\n')
    record=dict(name=name,spec=spec,bundle_manifest_sha256=digest,ranks=ranks)
    record.update(run_cohort(ranks,65))
    if reject:
        assert record['exit_codes']==[1],record
        assert not (output/'rank-0/logits.json').exists()
        record['rejection']=(output/'rank-0/stderr.log').read_text().splitlines()[-1]
    else:
        assert all(code==0 for code in record['exit_codes']),record
        record['reports']=[read_report(Path(rank['local'])/'stdout.jsonl') for rank in ranks]
        for rank,report in zip(ranks,record['reports'],strict=True):
            assert report['schemaVersion']==5 and report['attentionOutputPrecision']==precision
            assert report['correctnessOnly'] is True and report['throughputMeasurementValid'] is False
            assert report['routingTraceEnabled' if trace else 'routingReplayEnabled'] is True
            if trace:
                capture=json.loads((Path(rank['local'])/'routing.json').read_text())
                assert capture['formatVersion']==2 and capture['identity']['attentionOutputPrecision']==precision
                untraced=Path(receipt['uninstrumented_references'][name]['directory'])/f'rank-{rank["rank"]}/logits.json'
                assert json.loads(untraced.read_text())==json.loads((Path(rank['local'])/'logits.json').read_text())
                rank['routing_sha256']=hashlib.sha256((Path(rank['local'])/'routing.json').read_bytes()).hexdigest()
            rank['logits_sha256']=hashlib.sha256((Path(rank['local'])/'logits.json').read_bytes()).hexdigest()
    (output/'run.json').write_text(json.dumps(record,indent=2)+'\n')
    receipt['executions'].append(dict(name=name,exit_codes=record['exit_codes'],bundle_manifest_sha256=digest,
        rejected=reject,run_sha256=hashlib.sha256((output/'run.json').read_bytes()).hexdigest()))
    save();print(name,record['exit_codes'],flush=True)

run('wide-solo','float32',trace=True)
run('wide-full','float32',full=True,trace=True)
wide_reference=OUT/'wide-solo/rank-0/routing.json'
run('wide-replay','float32',replay=wide_reference)
assert json.loads((OUT/'wide-replay/rank-0/logits.json').read_text())==json.loads((OUT/'wide-solo/rank-0/logits.json').read_text())
old=Path('/Users/developer/DarkbloomDev/cluster-research/runs/qwen-moe-routing-20260913/bfloat16-solo/rank-0/routing.json')
run('legacy-native-replay','native',replay=old)
assert json.loads((OUT/'legacy-native-replay/rank-0/logits.json').read_text())==json.loads((NORMAL/'qwen-moe-bfloat16-seed7-native-solo/rank-0/logits.json').read_text())
run('reject-legacy-wide-policy','float32',replay=old,reject=True)
run('reject-current-native-policy','native',replay=wide_reference,reject=True)
receipt['baseline_replays_exact']=True;save()
print(OUT/'receipt.json',flush=True)
