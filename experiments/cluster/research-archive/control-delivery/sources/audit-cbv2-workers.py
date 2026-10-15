"""CPU-only validation of saved native worker protocol/state-isolation evidence."""
import hashlib,json,math,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path('/Users/developer/DarkbloomDev/cluster-research');BASE=ROOT/'runs/cbv2-workers-20260913'
sys.path.insert(0,str(BASE/'source'))
from runtime import persistent_protocol as protocol
from runtime.configuration import validate
from runtime.reports import reports
from runtime.artifacts import verify_files,file_sha256
sha=lambda p:file_sha256(p)
load=lambda p:json.loads(p.read_text())
r=load(BASE/'receipt.json');manifest=load(BASE/'source-manifest.json')
assert sha(BASE/'source-manifest.json')==r['source_manifest_sha256']
for e in manifest:assert sha(BASE/'source'/Path(e['path']).relative_to('experiments/cluster'))==e['sha256']
assert sha(BASE/'validate-cbv2-workers.py')==r['driver_sha256']
assert r['synthetic_only'] is True and r['performance_qualification'] is False
expected={f'{p}-{d}-{s}' for p,d in [('tiny','float32'),('tiny','bfloat16'),('qwen27-heads','bfloat16')] for s in ['solo','ffn','full']}
assert len(r['cohorts'])==9 and {x['name'] for x in r['cohorts']}==expected
A=[3+(i*17+7)%509 for i in range(65)];B=[3+(i*13+31)%509 for i in range(37)]
requests=[('A-first',A,6,32,None),('B',B,6,16,[12,25,38,51,64]),('A-last',A,6,32,None),('single',[3],1,1,None)]
result=[];inputs={};totals=dict(cohorts=0,loaded_native_ranks=0,logical_requests=0,rank_completed_events=0,rank_token_events=0,callback_tokens=0,peer_request_logit_pairs=0,
  one_shot_executions=0,one_shot_native_ranks=0,stopped_frames=0,verified_bundle_directories=0,model_reduction_hook_logs=0,rank_model_reduction_calls=0,rank_forward_observations=0,
  local_argmax_disagreements=0)
for c in r['cohorts']:
    name=c['name'];d=BASE/name;s=load(d/'session.json');spec=validate(load(BASE/(name+'.spec.json')))
    assert s['spec']==spec and s['state']==c['final_state']=='closed' and c['ABA_exact'] is True and c['oneshot_exact'] is True
    ready=c['ready'];assert s['ready']==ready and len(ready)==len(spec['ranks'])
    assert len(c['requests'])==4 and [x['request_id'] for x in c['requests']]==[x[0] for x in requests]
    bm=d/'bundle/bundle.json';assert sha(bm)==s['bundle_manifest_sha256'];verified=verify_files(d/'bundle',load(bm)['files'])
    assert verified['cluster-inference']==r['binary_sha256'];totals['verified_bundle_directories']+=1
    epoch=s['epoch'];byrank=[]
    for rank,rd in enumerate(ready):
        protocol.ready(rd,epoch,rank,spec)
        assert rd['modelLoadCount']==1 and rd['identity']['executionPath']=='cbv2-contiguous'
        assert rd['identity']==ready[0]['identity'] and rd['identitySHA256']==ready[0]['identitySHA256']
        p=d/f'rank-{rank}';frames=[json.loads(line) for line in (p/'stdout.jsonl').read_text().splitlines() if line.strip()]
        assert frames[0]==rd and sum(x['type']=='ready' for x in frames)==1
        byrank.append(frames);inputs[f'{name}/rank-{rank}/stdout.jsonl']=sha(p/'stdout.jsonl');inputs[f'{name}/rank-{rank}/stderr.log']=sha(p/'stderr.log')
        args=load(p/'rank.json')['arguments'];assert args.count('--execution-path')==1 and args[args.index('--execution-path')+1]=='cbv2-contiguous'
        lines=[tuple(map(int,x)) for x in re.findall(r'^CBv2 model reduction hooks verified: (\d+) across (\d+) forwards$',(p/'stderr.log').read_text(),re.M)]
        if len(ready)==2:
            factor=rd['identity']['layerCount']*(2 if rd['identity']['partition']=='full' else 1)
            forwards=[math.ceil(len(prompt)/chunk)+count-1 for _,prompt,count,chunk,_ in requests]
            assert lines==[(factor*f,f) for f in forwards]
        else:assert not lines
        totals['model_reduction_hook_logs']+=len(lines);totals['rank_model_reduction_calls']+=sum(x[0] for x in lines);totals['rank_forward_observations']+=sum(x[1] for x in lines)
    positions=[1]*len(ready)
    for seq,((rid,prompt,count,chunk,teacher),stored) in enumerate(zip(requests,c['requests'],strict=True),1):
        command=dict(version=4,type='infer',epoch=epoch,sequence=seq,requestID=rid,prompt=prompt,outputTokens=count,chunkSize=chunk,timeoutSeconds=30,captureLogits=True)
        if teacher is not None:command['teacherTokens']=teacher
        expected_hash=hashlib.sha256(json.dumps(command,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        assert s['requests'][seq-1]==dict(sequence=seq,requestID=rid,requestSHA256=expected_hash,status='completed')
        assert stored['tokens']==[[i,t] for i,t in enumerate(stored['events'][0]['result']['generatedTokens'])]
        for rank,rd in enumerate(ready):
            frames=byrank[rank];pos=positions[rank];accepted=frames[pos];protocol.frame(accepted,'accepted',epoch,rank,seq,command,rd['modelLoadID'])
            tokens=[]
            for step in range(count):
                event=frames[pos+1+step];protocol.frame(event,'token',epoch,rank,seq,command)
                assert event['step']==step and type(event['token']) is int;tokens.append(event['token'])
            event=frames[pos+1+count];protocol.completed(event,command,rd,rank,tokens)
            assert event==stored['events'][rank] and event['logits']==stored['events'][0]['logits']
            assert event['result']['localArgmaxTokens']==tokens
            if rid=='single':assert event['result']['decodeForwardCount']==0 and event['result']['decodeInputTokens']==[]
            positions[rank]=pos+2+count;totals['rank_completed_events']+=1;totals['rank_token_events']+=count
            totals['local_argmax_disagreements']+=event['result']['localArgmaxDisagreementCount']
        totals['logical_requests']+=1;totals['callback_tokens']+=count
        if len(ready)==2:totals['peer_request_logit_pairs']+=1
    for rank,frames in enumerate(byrank):
        assert len(frames)==positions[rank]+1
        protocol.frame(frames[-1],'stopped',epoch,rank,5);totals['stopped_frames']+=1
        a,b=c['requests'][0]['events'][rank],c['requests'][2]['events'][rank]
        assert a['logits']==b['logits']
        for k in ['generatedTokens','decodeInputTokens','localArgmaxTokens']:assert a['result'][k]==b['result'][k]
    one=BASE/(name+'-oneshot');run=load(one/'run.json');assert run['verified_execution'] is True and run['hardware_throughput_candidate'] is False and run['exit_codes']==[0]*len(ready)
    assert run['spec']==spec and reports(run['ranks'],spec)==run['reports']
    bm=one/'bundle/bundle.json';assert sha(bm)==run['bundle_manifest_sha256'];verified=verify_files(one/'bundle',load(bm)['files']);assert verified['cluster-inference']==r['binary_sha256'];totals['verified_bundle_directories']+=1
    for rank,report in enumerate(run['reports']):
        assert report['executionPath']=='cbv2-contiguous'
        event=c['requests'][0]['events'][rank];p=one/f'rank-{rank}';assert load(p/'logits.json')==event['logits']
        for k in ['generatedTokens','decodeInputTokens','localArgmaxTokens']:assert report['runs'][0][k]==event['result'][k]
        assert report['configurationSHA256']==ready[rank]['identity']['configurationSHA256']
        assert report['parameterLayoutSHA256']==ready[rank]['parameterLayoutSHA256']
        lines=[tuple(map(int,x)) for x in re.findall(r'^CBv2 model reduction hooks verified: (\d+) across (\d+) forwards$',(p/'stderr.log').read_text(),re.M)]
        if len(ready)==2:assert lines==[(8*4*(2 if report['partition']=='full' else 1),8)]
        else:assert not lines
        totals['model_reduction_hook_logs']+=len(lines);totals['rank_model_reduction_calls']+=sum(x[0] for x in lines);totals['rank_forward_observations']+=sum(x[1] for x in lines)
        for f in ['logits.json','stdout.jsonl','stderr.log']:inputs[f'{name}-oneshot/rank-{rank}/{f}']=sha(p/f)
    for p in [d/'session.json',one/'run.json',BASE/(name+'.spec.json')]:inputs[str(p.relative_to(BASE))]=sha(p)
    totals['cohorts']+=1;totals['loaded_native_ranks']+=len(ready);totals['one_shot_executions']+=1;totals['one_shot_native_ranks']+=len(ready)
    result.append(dict(name=name,ranks=len(ready),ready_identity_sha256=ready[0]['identitySHA256'],epoch=epoch,all_model_load_ids_stable=True,ABA_exact=True,one_shot_exact=True,all_peers_exact=True,all_frames_and_request_hashes_valid=True,stopped_sequence=5))
answer=dict(scope='CPU-only saved protocol, output, artifact, and aggregate-hook audit; no process execution',receipt_sha256=sha(BASE/'receipt.json'),
 binary_sha256=r['binary_sha256'],source_manifest_sha256=r['source_manifest_sha256'],archived_source_files_verified=len(manifest),driver_sha256=r['driver_sha256'],
 totals=totals,cohorts=result,inputs=inputs,audit_script_sha256=sha(Path(__file__)),
 limitations=['Worker-vs-one-shot and A/B/A equivalence are tested per partition; this does not qualify TP-vs-solo BF16 accuracy.',
 'Closed session and native stopped frames are verified; no post-hoc assertion about all descendant PIDs is inferred from saved frames.',
 'Source archive scope is the experiment, not a full attestation of local build dependencies.'])
p=ROOT/'cbv2-workers-independent-audit-20260913.json';p.write_text(json.dumps(answer,indent=2)+'\n');print(json.dumps(dict(totals=totals,output=str(p)),indent=2))
