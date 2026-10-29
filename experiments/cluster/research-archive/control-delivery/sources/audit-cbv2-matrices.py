"""Offline independent audit: no native/model execution, network, or repository writes."""
import collections, hashlib, itertools, json, math, re, sys
from pathlib import Path
ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
REPO=Path('/Users/developer/DarkbloomDev/d-inference')
# Use the archived validators whose hashes are checked below.
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT/'runs/cbv2-inference-20260913/source'))
from runtime.configuration import validate
from runtime.reports import reports
from runtime.artifacts import verify_files

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()
def load(p):return json.loads(p.read_text())
def metrics(a,b):
    assert len(a)==len(b)==8
    rows=[]
    for i,(x,y) in enumerate(zip(a,b,strict=True)):
        assert len(x)==len(y)==512 and all(type(z) in (int,float) and math.isfinite(z) for z in x+y)
        err=[u-v for u,v in zip(x,y,strict=True)]
        den=math.fsum(u*u for u in x)
        assert den>0
        rows.append(dict(row=i,max_absolute=max(map(abs,err)),relative_rms=math.sqrt(math.fsum(z*z for z in err)/den),argmax_equal=x.index(max(x))==y.index(max(y))))
    return dict(rows=rows,exact=a==b,passed=all(r['max_absolute']<.001 and r['relative_rms']<.0001 and r['argmax_equal'] for r in rows))
def summarize(cases):
    rows=[r for c in cases for r in c['rows']]
    worst=max(((r['relative_rms'],c,r) for c in cases for r in c['rows']),key=lambda x:x[0])
    return dict(cases=len(cases),passed=sum(c['passed'] for c in cases),exact=sum(c['exact'] for c in cases),rows=len(rows),
        max_absolute=max(r['max_absolute'] for r in rows),max_relative_rms=worst[0],
        argmax_disagreement_rows=sum(not r['argmax_equal'] for r in rows),
        nonzero_error_rows=sum(r['max_absolute']!=0 for r in rows),
        worst_relative_rms_case={**{k:v for k,v in worst[1].items() if k not in ('rows','passed','exact')},'row':worst[2]['row']})

def audit(name,long=False,tail=False):
    base=ROOT/'runs'/name;receipt=load(base/'receipt.json')
    expected=set(itertools.product(['qwen27-heads'] if long or tail else ['tiny','qwen9-heads','qwen27-heads'],['float32','bfloat16'],[7] if long else [7,31],['ordinary','cbv2-contiguous'],['solo','ffn','full']))
    names={f'{p}-{d}-seed{s}-{x}-{part}' for p,d,s,x,part in expected}
    assert len(receipt['executions'])==len(names) and {e['name'] for e in receipt['executions']}==names
    assert receipt['synthetic_only'] is True and receipt['performance_qualification'] is False
    manifest=load(base/'source-manifest.json')
    assert sha(base/'source-manifest.json')==receipt['source_manifest_sha256']
    assert len({m['path'] for m in manifest})==len(manifest)
    current_changes=[]
    for m in manifest:
        rel=Path(m['path']).relative_to('experiments/cluster')
        assert sha(base/'source'/rel)==m['sha256'],m
        if sha(REPO/m['path'])!=m['sha256']: current_changes.append(m['path'])
    drivers=list(base.glob('validate-*.py'));assert len(drivers)==1 and sha(drivers[0])==receipt['driver_sha256']
    for f,h in receipt['bundle_files'].items():assert sha(base/'bundle'/f)==h
    assert receipt['binary_sha256']==receipt['bundle_files']['cluster-inference']
    results={};logits={};hooks=[];hashes={};reports_total=0;rank_disagreement=0;bundles=0;peer_values=0
    for e in receipt['executions']:
        n=e['name'];d=base/n;rec=load(d/'run.json');rawspec=load(base/(n+'.spec.json'));spec=validate(rawspec)
        assert e['exit_code']==0 and e['verified_execution'] is True and rec['verified_execution'] is True
        assert rec['spec']==spec and rec['hardware_throughput_candidate'] is False and rec['cancellation_reason'] is None
        assert rec['exit_codes']==[0]*len(spec['ranks']) and e['bundle_manifest_sha256']==rec['bundle_manifest_sha256']
        bm=d/'bundle/bundle.json';assert sha(bm)==rec['bundle_manifest_sha256']
        entries=load(bm)['files'];verified=verify_files(d/'bundle',entries);bundles+=1
        assert all(verified[k]==v for k,v in receipt['bundle_files'].items())
        assert verified['artifacts.py']==next(m['sha256'] for m in manifest if m['path']=='experiments/cluster/runtime/artifacts.py')
        assert verified['rank_worker.py']==next(m['sha256'] for m in manifest if m['path']=='experiments/cluster/runtime/rank_worker.py')
        actual=reports(rec['ranks'],spec);assert actual==rec['reports']
        work=spec['workload'];is_tp=spec['backend']=='loopback-test';path=work['execution_path'];values=[]
        for rank,r in enumerate(actual):
            reports_total+=1
            assert r['syntheticWeights'] is True and r['schemaVersion']==8 and r['executionPath']==path
            assert r['modelFamily']=='qwen35' and r['feedForwardKind']=='dense'
            assert r['attentionOutputPrecision']=='native' and r['ffnBranchPrecision']=='native'
            assert r['promptSource']=='synthetic-token-ids' and r['teacherForced'] is True
            assert r['embeddingActivationDType']==work['synthetic_dtype'] and r['ffnScaleDTypes']==[work['synthetic_dtype']]
            run=r['runs'][0];assert run['decodeInputTokens']==[12,25,38,51,64,77,90]
            assert run['promptTokens']==(8184 if long else (66 if work['seed']==7 else 96) if tail else 65 if work['seed']==7 else 97)
            assert r['chunkSize']==(512 if long else 32 if tail or work['seed']==7 else 16)
            assert run['decodeForwardCount']==7 and len(run['generatedTokens'])==8 and len(actual)==(2 if is_tp else 1)
            rank_disagreement+=run['localArgmaxDisagreementCount']
            rd=d/f'rank-{rank}';v=load(rd/'logits.json');metrics(v,v)
            assert [row.index(max(row)) for row in v]==run['localArgmaxTokens']==run['generatedTokens']
            values.append(v)
            rc=load(rd/'rank.json');args=rc['arguments'];assert args.count('--execution-path')==1 and args[args.index('--execution-path')+1]==path
            assert rc['input_files']['teacher.json']==load(rd/'teacher.json')==work['teacher_tokens']
            lines=re.findall(r'^CBv2 model reduction hooks verified: (\d+) across (\d+) forwards$',(rd/'stderr.log').read_text(),re.M)
            if path=='cbv2-contiguous' and is_tp:
                assert len(lines)==1
                count,forwards=map(int,lines[0]);expected_forwards=math.ceil(work['prompt_tokens']/work['chunk_size'])+7
                assert forwards==expected_forwards and count==forwards*r['shardedFFNs']*(2 if r['partition']=='full' else 1)
                hooks.append(dict(execution=n,rank=rank,count=count,forwards=forwards,partition=r['partition']))
            else:assert not lines
            for f in ('stdout.jsonl','stderr.log','rank.json','logits.json','teacher.json'):hashes[f'{n}/rank-{rank}/{f}']=sha(rd/f)
        assert all(v==values[0] for v in values)
        if is_tp:peer_values+=8*512
        logits[n]=values[0];results[n]=actual
        hashes[f'{n}/run.json']=sha(d/'run.json');hashes[n+'.spec.json']=sha(base/(n+'.spec.json'))
    recalc=[];path_recalc=[]
    for category,out in [('comparisons',recalc),('path_comparisons',path_recalc)]:
        identities=[]
        for c in receipt[category]:
            p,d,s,part=(c[k] for k in ('profile','dtype','seed','partition'))
            prefix=f'{p}-{d}-seed{s}-'
            an,bn=(prefix+c['path']+'-solo',prefix+c['path']+'-'+part) if category=='comparisons' else (prefix+'ordinary-'+part,prefix+'cbv2-contiguous-'+part)
            identity={k:v for k,v in c.items() if k not in ('rows','exact','passed')};identities.append(tuple(identity.values()))
            computed=metrics(logits[an],logits[bn]);assert {k:c[k] for k in computed}==computed,(name,category,identity)
            ra,rb=results[an][0],results[bn][0]
            for field in ('configurationSHA256','promptSHA256','teacherSHA256','seed','syntheticDType','embeddingActivationDType','ffnScaleDTypes','syntheticProfile','modelFamily','feedForwardKind','attentionOutputPrecision','ffnBranchPrecision'):
                assert ra[field]==rb[field],(an,bn,field)
            if category=='path_comparisons':
                for field in ('partition','partitionPlanSHA256','partitionStorage','parameterLayoutSHA256','transport','tokenSelectionPolicy','model','shardedFFNs'):
                    assert ra.get(field)==rb.get(field),(an,bn,field)
            out.append({**identity,**computed})
        assert len(set(identities))==len(identities)
    expected_groups=len(expected)//6
    assert len(recalc)==expected_groups*4 and len(path_recalc)==expected_groups*3
    return dict(directory=str(base),receipt_sha256=sha(base/'receipt.json'),binary_sha256=receipt['binary_sha256'],driver_sha256=receipt['driver_sha256'],
        source_manifest_sha256=receipt['source_manifest_sha256'],archived_source_files_verified=len(manifest),current_source_changes=current_changes,
        executions=len(results),native_rank_reports=reports_total,staged_bundles_verified=bundles,all_execution_records_and_reports_valid=True,
        all_raw_logits_match_report_argmax=True,peer_logit_pairs=sum(len(x)==2 for x in results.values()),peer_logit_values_compared=peer_values,peer_logits_exact=True,rank_argmax_disagreements=rank_disagreement,
        tp_vs_solo={d:summarize([c for c in recalc if c['dtype']==d]) for d in ('float32','bfloat16')},
        ordinary_vs_cbv2={d:summarize([c for c in path_recalc if c['dtype']==d]) for d in ('float32','bfloat16')},
        all_receipt_metrics_independently_reproduced=True,hook_logs=len(hooks),rank_model_hook_calls=sum(x['count'] for x in hooks),rank_forward_observations=sum(x['forwards'] for x in hooks),
        hook_events=hooks,path_comparisons=path_recalc,failed_tp_comparisons=[{k:v for k,v in c.items() if k!='rows'} for c in recalc if not c['passed']],
        input_hashes=hashes)

answer=dict(scope='CPU-only re-read of existing synthetic teacher-forced outputs; no inference or performance qualification',
    gate=dict(max_absolute_strictly_less_than=.001,row_relative_rms_strictly_less_than=.0001,argmax_equal=True),
    matrices=[audit('cbv2-inference-20260913'),audit('cbv2-context-bound-20260913',True),audit('cbv2-tail-shapes-20260913',tail=True)],
    limitations=[
      'All weights and prompt IDs are synthetic; profiles preserve selected head geometry but are four-layer, 512-vocabulary fixtures, not actual 9B/27B checkpoints.',
      'Teacher forcing fixes seven consumed continuation tokens, so these runs do not establish free-running greedy trajectory parity.',
      'Model reduction hooks prove the aggregate count (4 per FFN forward, 8 per full forward); logs do not individually identify each operator hook.',
      '126-file experiment archives omit local path dependencies libs/mlx-swift-lm and generated MLX source trees. Bundle content is verified, but these receipts alone do not fully attest build-source provenance.',
      'Short cases have final prefill chunk length 1; long case has final chunk length 504. Qwen35 CBv2 lastPositionLogits narrows hidden before norm/head, ordinary handles the full chunk. Shape-sensitive arithmetic is plausible; output-only evidence does not isolate norm, projection, or earlier state as the cause.',
      'Seven exact long-context teacher decode rows constrain but do not prove equality of all hidden/cache/recurrent states.'])
answer['audit_script_sha256']=sha(Path(__file__))
p=ROOT/'cbv2-matrices-independent-audit-20260913.json';p.write_text(json.dumps(answer,indent=2)+'\n')
print(json.dumps({**{k:v for k,v in answer.items() if k not in ('matrices','limitations')},'matrices':[{k:v for k,v in m.items() if k not in ('input_hashes','hook_events','path_comparisons','failed_tp_comparisons')} for m in answer['matrices']],'output':str(p)},indent=2))
