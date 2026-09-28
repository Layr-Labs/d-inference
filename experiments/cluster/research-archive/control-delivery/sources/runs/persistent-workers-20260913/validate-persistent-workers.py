"""Synthetic persistent-worker state isolation and one-shot equivalence checks."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER = REPO / 'experiments/cluster'
sys.path.insert(0, str(CLUSTER))
from runtime.persistent import PersistentCohort

BUNDLE = CLUSTER / 'inference/.build/arm64-apple-macosx/release'
OUT = Path(sys.argv[1])
OUT.mkdir(mode=0o700, parents=True, exist_ok=False)
receipt = dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
               driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               synthetic_only=True, performance_qualification=False, cohorts=[])

def save():
    (OUT/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')

for profile, dtype in [('tiny','float32'), ('qwen-moe','float32'), ('qwen27-heads','bfloat16')]:
    for distributed in (False, True):
        name = f'{profile}-{dtype}-' + ('full' if distributed else 'solo')
        prompt_a = [3 + (i*17+7)%509 for i in range(65)]
        prompt_b = [3 + (i*13+31)%509 for i in range(37)]
        spec = dict(schema_version=1, backend='loopback-test' if distributed else 'solo',
            ranks=[dict(location='local') for _ in range(2 if distributed else 1)],
            partition='full' if distributed else 'ffn', timeout_seconds=60,
            capture_logits=True, workload=dict(synthetic=True, synthetic_profile=profile,
                synthetic_dtype=dtype, attention_output_precision='native', seed=7,
                prompt_ids=prompt_a, prompt_tokens=65, chunk_size=32, decode_tokens=6,
                repeats=1,warmups=0))
        record = dict(name=name, requests=[])
        with PersistentCohort(spec, BUNDLE, OUT/name) as cohort:
            record['ready'] = cohort.ready
            for request_id, prompt, chunk, teacher in [
                ('A-first', prompt_a,32,None), ('B',prompt_b,16,[12,25,38,51,64]),
                ('A-last', prompt_a,32,None)]:
                tokens=[]
                result=cohort.infer(request_id,prompt,6,chunk,teacher_tokens=teacher,
                    capture_logits=True,timeout_seconds=30,on_token=lambda step,token:tokens.append([step,token]))
                assert tokens==list(map(list,enumerate(result[0]['result']['generatedTokens'])))
                assert all(r['modelLoadID']==ready['modelLoadID'] for r,ready in zip(result,cohort.ready,strict=True))
                assert all(r['logits']==result[0]['logits'] for r in result)
                record['requests'].append(dict(request_id=request_id,events=result,tokens=tokens))
            first,last=record['requests'][0]['events'],record['requests'][2]['events']
            for a,b in zip(first,last,strict=True):
                assert a['logits']==b['logits'], 'A/B/A cache or state leakage'
                for key in ('generatedTokens','decodeInputTokens','localArgmaxTokens'):
                    assert a['result'][key]==b['result'][key]
            record['ABA_exact']=True
        record['final_state']=cohort.state
        assert cohort.state=='closed' and cohort.epoch is None
        specfile=OUT/(name+'.spec.json')
        specfile.write_text(json.dumps(spec,indent=2)+'\n')
        oneshot=OUT/(name+'-oneshot')
        with (OUT/(name+'.oneshot.stdout')).open('w') as stdout,(OUT/(name+'.oneshot.stderr')).open('w') as stderr:
            subprocess.run([sys.executable,str(CLUSTER/'run_inference.py'),'--spec',str(specfile),
                '--bundle',str(BUNDLE),'--output',str(oneshot)],check=True,stdout=stdout,stderr=stderr,timeout=70)
        report=json.loads((oneshot/'run.json').read_text())
        assert report['verified_execution'] and not report['hardware_throughput_candidate']
        for rank,event in enumerate(first):
            assert json.loads((oneshot/f'rank-{rank}/logits.json').read_text())==event['logits']
            for key in ('generatedTokens','decodeInputTokens','localArgmaxTokens'):
                assert report['reports'][rank]['runs'][0][key]==event['result'][key]
        record['oneshot_exact']=True
        receipt['cohorts'].append(record)
        save()
        print(name,'A/B/A and one-shot exact; one model load per rank',flush=True)
print('Evidence:',OUT/'receipt.json',flush=True)
