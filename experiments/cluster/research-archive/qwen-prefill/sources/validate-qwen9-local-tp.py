#!/usr/bin/env python3
"""Six opt-in real9B local correctness runs. Native execution belongs to root only.

--prepare-only verifies and snapshots without launching native inference. A failed
resource gate stops the driver; there is no override and no user process cleanup.
Numeric gate misses are retained and do not prevent later matched controls.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import struct
import sys

sys.dont_write_bytecode = True
from qwen9_local_tp_support import (previous, require, sha, read_json, write_json, now,
    preflight, bounded_launch, compare, PREVIOUS_DRIVER_SHA, SOURCE_BYTES, LOADED_BYTES,
    LARGEST_SELECTED_HOST_BYTES)

REPO, CLUSTER, RELEASE, MODEL = previous.REPO, previous.CLUSTER, previous.RELEASE, previous.MODEL
HERE=Path(__file__).resolve().parent
INPUT=HERE/'runs/qwen9-output-boundaries-20260913'
CONFIG='c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
AGGREGATE=previous.AGGREGATE
INPUT_RECEIPT='0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1'
TEACHER=[4087,13,271]
SOURCE_SHARDED={'ffn':2717908992,'full':3893236224}
INPUT_HASHES={
 'prompt-96.json':'36b9329c650a57fb8c5a30c13aeafc8155047d14527f62d824c3e7e104a968d2',
 'tokenization.json':'742eb6896e4b936ecb667cc694029a6f456fbbb9d2a5c9af551dc9703b142c11',
 'source-text.txt':'6a76e63af205e75c3e702a7e85be76d1d0575133d9deffd171d6de6e7b3db920',
 'baseline-teacher.json':'f6dc33043869d9caed9f2835f35ac9b8b4a32bd2277b35884804612b0078def0'}


def inventory():
    """Pinned-artifact planning inventory; actual native receipts remain authoritative."""
    items={};files=[]
    for path in sorted(MODEL.glob('*.safetensors')):
        with path.open('rb') as stream:
            size=struct.unpack('<Q',stream.read(8))[0]
            require(0<size<16*1024**2,'Unbounded safetensors header')
            data=stream.read(size);header=json.loads(data)
        files.append(dict(path=path.name,header_bytes=size,header_sha256=hashlib.sha256(data).hexdigest()))
        for name,value in header.items():
            if not name.startswith('language_model.'):continue
            require(name not in items,'Duplicate text tensor')
            start,end=value['data_offsets'];shape=value['shape'];dtype=value['dtype']
            require(type(start)is int and type(end)is int and 0<=start<end<=path.stat().st_size-size-8,
                    'Invalid safetensors range')
            require(dtype in ('BF16','F16','F32','U32') and all(type(x)is int and x>0 for x in shape),'Invalid tensor metadata')
            require(end-start==math.prod(shape)*{'BF16':2,'F16':2,'F32':4,'U32':4}[dtype],'Tensor bytes differ from shape/dtype')
            items[name]=dict(shape=shape,dtype=dtype,bytes=end-start,source=path.name)
    ffn=lambda n:'.mlp.' in n
    full=lambda n:ffn(n) or ('.self_attn.' in n and not any(t in n for t in ('q_norm.','k_norm.'))) or ('.linear_attn.' in n and '.norm.' not in n)
    total=sum(v['bytes'] for v in items.values())
    require(len(items)==927 and total==SOURCE_BYTES,'Canonical pinned text inventory changed')
    result=dict(canonical_text_tensors=len(items),canonical_source_bytes=total,files=files,
        metadata_sha256=hashlib.sha256(json.dumps(items,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
        excluded_prefixes=['vision_tower.','mtp.'],partitions={})
    for name,predicate in [('ffn',ffn),('full',full)]:
        sharded=sum(v['bytes'] for n,v in items.items() if predicate(n))
        require(sharded==SOURCE_SHARDED[name],'Pinned sharded tensor byte count changed')
        require(all(v['bytes']%2==0 for n,v in items.items() if predicate(n)),'Cannot halve selected bytes')
        loaded=total-sharded//2
        largest=max(v['bytes']//2 if predicate(n) else v['bytes'] for n,v in items.items())
        require(loaded==LOADED_BYTES[name] and largest==LARGEST_SELECTED_HOST_BYTES,'Planning inventory changed')
        result['partitions'][name]=dict(source_sharded_bytes=sharded,per_rank_loaded_bytes=loaded,
            largest_selected_host_tensor_bytes=largest,source_tensor_count=927)
    return result


def arguments_match(config, spec):
    args=config['arguments'];work=spec['workload'];distributed=spec['backend']=='loopback-test'
    def value(flag):
        require(args.count(flag)==1,'Missing/duplicate argument '+flag)
        return args[args.index(flag)+1]
    for flag,expected in [('--model-dir','@model'),('--execution-path','cbv2-contiguous'),
        ('--attention-output-precision',work['attention_output_precision']),
        ('--ffn-output-precision',work['ffn_output_precision']),('--ffn-branch-precision','native'),
        ('--prompt-tokens','96'),('--chunk-size','32'),('--decode-tokens','4'),
        ('--repeats','1'),('--warmups','0'),('--timeout-seconds','170')]:
        require(value(flag)==expected,'Native argv differs: '+flag)
    require(config['artifact_aggregate_sha256']==AGGREGATE and config['model_directory']==str(MODEL),'Rank artifact binding changed')
    require(config['input_files']['prompt.json']==spec['workload']['prompt_ids'] and
            config['input_files']['teacher.json']==TEACHER,'Rank history changed')
    require(('--local-correctness' in args)==distributed,'Local correctness argv differs')
    if distributed:require(value('--artifact-aggregate-sha256')==AGGREGATE,'Native aggregate opt-in differs')
    require('--synthetic' not in args and value('--logits-file')=='@rank/logits.json','Capture/model args differ')


def make_specs(prompt, partitions, validate):
    specs={}
    for policy in ('native','both-wide'):
        for partition in partitions:
            distributed=partition!='solo';name=f'{policy}-{partition}'
            spec=dict(schema_version=1,backend='loopback-test' if distributed else 'solo',
                partition=partition if distributed else 'ffn',
                ranks=[dict(location='local',model_directory=str(MODEL)) for _ in range(2 if distributed else 1)],
                artifact_aggregate_sha256=AGGREGATE,timeout_seconds=170,capture_logits=True,
                workload=dict(synthetic=False,execution_path='cbv2-contiguous',seed=7,
                    prompt_ids=prompt,prompt_tokens=96,chunk_size=32,decode_tokens=4,warmups=0,repeats=1,
                    teacher_tokens=TEACHER,attention_output_precision='native' if policy=='native' else 'float32',
                    ffn_output_precision='native' if policy=='native' else 'float32',ffn_branch_precision='native'))
            if distributed:spec['local_correctness']=True
            specs[name]=validate(spec)
    return specs

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--plans',choices=('all','full'),default='all',help='all: six runs; full: four solo/full runs, recorded as a subset')
    args=parser.parse_args();out=args.output.resolve()
    partitions=('solo','ffn','full') if args.plans=='all' else ('solo','full')
    planned_runs=2*len(partitions)
    require(not out.exists() and not out.is_relative_to(REPO),'Output must be new and outside Git')
    out.mkdir(mode=0o700,parents=True)
    receipt=dict(schema_version=1,started_at=now(),status='preparing',planned_logical_runs=planned_runs,selected_partitions=partitions,requested_subset=args.plans,
        executions=[],matched_comparisons=[],policy_departures=[],real_artifact=True,
        hardware_throughput_qualification=False,numerical_qualification=False,model_quality_qualification=False,
        controlled_teacher_history=True,execution_path='cbv2-contiguous',prompt_tokens=96,chunk_size=32,
        output_tokens=4,teacher_tokens=TEACHER,expected_model_aggregate_sha256=AGGREGATE,
        expected_configuration_sha256=CONFIG,strict_diagnostic_gate=previous.GATE,
        limitations=['One registered real9B artifact and fixed prose prefix; no chat template or model-quality assessment.',
            'Two local processes share one Mac/GPU; loopback timings are not hardware-cluster throughput.',
            'Memory planning uses selected stored bytes plus prior solo overhead and host-buffer margin; it is an estimate, not a safety guarantee.',
            'Memory pressure and RSS are sampled; short transients between samples may be missed. Startup/loading MLX figures are not RSS or total OS memory.',
            'Fail-closed execution/identity/peer checks; numerical gate failures remain recorded without loosening bounds.',
            'Archived source/bundle fingerprints are integrity evidence, not reproducible-build attestation.'])
    save=lambda:write_json(out/'receipt.json',receipt)
    try:
        require(sha(HERE/'validate-qwen9-output-boundaries.py')==PREVIOUS_DRIVER_SHA,'Prior helper changed')
        scripts={}
        for name in (Path(__file__).name,'qwen9_local_tp_support.py','validate-qwen9-output-boundaries.py'):
            shutil.copy2(HERE/name,out/name);scripts[name]=sha(out/name)
        receipt['driver_files_sha256']=scripts;save()
        sources,dependencies=previous.snapshot_sources(out)
        receipt.update(source_manifest_sha256=sha(out/'source-manifest.json'),dependencies=dependencies)
        previous.verify_sources(out,sources)
        # Invoke the archived, hash-checked launcher/runtime, not mutable imports.
        archived_cluster=out/'source/experiments/cluster'
        sys.path.insert(0,str(archived_cluster))
        from runtime.artifacts import verify_model,verify_files
        from runtime.bundle import snapshot
        from runtime.configuration import validate
        from runtime.reports import reports
        receipt['bundle_manifest_sha256']=snapshot(RELEASE,out/'bundle')
        entries=read_json(out/'bundle/bundle.json')['files']
        receipt['bundle_files']=verify_files(out/'bundle',entries)
        receipt['binary_sha256']=receipt['bundle_files']['cluster-inference']
        require(sha(MODEL/'config.json')==CONFIG,'Config pin changed')
        receipt['model_before_aggregate_sha256']=verify_model(MODEL,AGGREGATE)
        shutil.copy2(MODEL/'manifest.json',out/'model-manifest.json')
        receipt['model_manifest_sha256']=sha(out/'model-manifest.json')
        receipt['inventory']=inventory();write_json(out/'tensor-inventory.json',receipt['inventory'])
        require(sha(INPUT/'receipt.json')==INPUT_RECEIPT,'Prior evidence receipt changed')
        old=read_json(INPUT/'receipt.json')
        require(old['model_verified_aggregate_sha256']==AGGREGATE and old['baseline_teacher_tokens']==TEACHER,'Teacher evidence changed')
        receipt['input_receipt_sha256']=INPUT_RECEIPT;receipt['input_files_sha256']=INPUT_HASHES
        for name,digest in INPUT_HASHES.items():
            require(sha(INPUT/name)==digest,'Saved prose/teacher input changed')
            shutil.copy2(INPUT/name,out/name)
        prompt=read_json(out/'prompt-96.json');tokenization=read_json(out/'tokenization.json')
        require(len(prompt)==96 and hashlib.sha256(previous.canonical(prompt)).hexdigest()==previous.PREFIX_SHA,'Prompt prefix changed')
        require(tokenization['prompt_ids']==prompt and not tokenization['chat_template_applied'],'Input tokenization differs')
        require(sha(MODEL/'tokenizer.json')==tokenization['tokenizer_json_sha256']==previous.TOKENIZER_SHA,'Tokenizer pin changed')
        require(read_json(out/'baseline-teacher.json')==TEACHER,'Teacher file differs')
        vocabulary=read_json(MODEL/'config.json')['text_config']['vocab_size']
        require(vocabulary==248320 and all(type(v)is int and 0<=v<vocabulary for v in prompt+TEACHER),'Invalid token IDs')
        receipt['vocabulary_size']=vocabulary
        specs=make_specs(prompt,partitions,validate)
        for name,spec in specs.items():write_json(out/(name+'.spec.json'),spec)
        receipt['preparation_preflight']=preflight('ffn' if 'ffn' in partitions else 'full',out);save()
        require(receipt['preparation_preflight']['passed'],'Preparation headroom/pressure/descriptors/disk gate refused; stop and report to root, no override')
        receipt['status']='prepared_not_executed' if args.prepare_only else 'running';save()
        if args.prepare_only:
            print(json.dumps(dict(output=str(out),status=receipt['status'],native_runs=0)));return 0
        controls={};env=previous.environment()
        for name,spec in specs.items():
            policy,partition=name.rsplit('-',1);distributed=partition!='solo'
            previous.verify_sources(out,sources)
            require(verify_files(out/'bundle',entries)==receipt['bundle_files'],'Bundle changed')
            require(verify_model(MODEL,AGGREGATE)==AGGREGATE and sha(MODEL/'config.json')==CONFIG,'Model changed')
            entry=dict(name=name,status='preflight',spec_sha256=sha(out/(name+'.spec.json')),
                       preflight=preflight(partition,out),model_before_aggregate_sha256=AGGREGATE)
            receipt['executions'].append(entry);save()
            require(entry['preflight']['passed'],'Run preflight refused; stop and report to root, no override')
            entry['status']='running';save();directory=out/name
            command=[sys.executable,str(archived_cluster/'run_inference.py'),'--spec',str(out/(name+'.spec.json')),
                     '--bundle',str(out/'bundle'),'--output',str(directory)]
            bounded_launch(command,directory,out/(name+'-launcher'),env,entry,save,partition)
            entry['postflight']=preflight(partition,out);save()
            require(not entry['postflight']['severe_pressure'],'Critical pressure after run')
            require(entry['postflight']['swap_used_bytes']-entry['preflight']['swap_used_bytes']<=1024**3,'More than 1GiB new swap after run')
            record=read_json(directory/'run.json')
            require(record['spec']==spec and record['exit_codes']==[0]*len(spec['ranks']) and
                    record['verified_execution'] and not record['hardware_throughput_candidate'] and
                    record['cancellation_reason'] is None,'Unverified execution')
            actual=reports(record['ranks'],spec);require(actual==record['reports'],'Raw reports differ')
            manifest=directory/'bundle/bundle.json'
            require(sha(manifest)==record['bundle_manifest_sha256'] and
                    verify_files(directory/'bundle',read_json(manifest)['files'])==receipt['bundle_files'],'Run bundle changed')
            outputs=[];entry['ranks']=[]
            for rank,report in enumerate(actual):
                require(report['schemaVersion']==9 and report['model']=='Qwen3.5-9B' and report['modelFamily']=='qwen35'
                    and report['feedForwardKind']=='dense' and report['vocabularySize']==vocabulary and not report['syntheticWeights'] and not report['mtpEnabled'], 'Wrong native model/schema')
                for field,expected in [('configurationSHA256',CONFIG),('executionPath','cbv2-contiguous'),
                    ('embeddingActivationDType','bfloat16'),('ffnScaleDTypes',['bfloat16']),('teacherForced',True),
                    ('attentionOutputPrecision',spec['workload']['attention_output_precision']),
                    ('ffnOutputPrecision',spec['workload']['ffn_output_precision'])]:
                    require(report[field]==expected,'Report identity differs: '+field)
                target=directory/f'rank-{rank}';arguments_match(read_json(target/'rank.json'),spec)
                result=report['runs'][0]
                require(result['decodeInputTokens']==TEACHER and result['decodeForwardCount']==3,'History/decode count differs')
                values=read_json(target/'logits.json');compare(values,values,vocabulary)
                require([row.index(max(row)) for row in values]==result['localArgmaxTokens'],'Captured argmax differs')
                outputs.append(values)
                startup=[]
                for line in (target/'stderr.log').read_text().splitlines():
                    if line.startswith('local-correctness-load-memory: '):
                        observed=json.loads(line.removeprefix('local-correctness-load-memory: '))
                        require(set(observed)=={'activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'} and
                            all(type(v)is int and v>=0 for v in observed.values()),'Invalid startup MLX memory observation')
                        require(observed['activeMLXBytes']<=observed['peakMLXBytesSinceProcessStart'],'Invalid MLX peak')
                        startup.append(observed)
                require(len(startup)==int(distributed),'Missing/duplicate/unexpected startup memory record')
                if distributed:
                    require(report['correctnessOnly'] and not report['throughputMeasurementValid'],'Local TP misclassified')
                    direct=report['directShardLoad']
                    require(direct['verifiedAggregateSHA256']==AGGREGATE and direct['sourceModelTensorBytes']==SOURCE_BYTES
                        and direct['sourceShardedTensorBytes']==SOURCE_SHARDED[partition]
                        and direct['loadedTensorBytes']==LOADED_BYTES[partition]
                        and direct['largestHostTensorBytes']==LARGEST_SELECTED_HOST_BYTES
                        and direct['sourceTensorCount']==927,'Direct reader differs from planning inventory')
                entry['ranks'].append(dict(rank=rank,logits_sha256=sha(target/'logits.json'),
                    startup_loading_mlx_observation=startup,run_peak_mlx_bytes=result['peakMLXBytes'],
                    run_active_mlx_bytes=result['activeMLXBytes'],generated_tokens=result['generatedTokens'],
                    native_timing_fields_diagnostic_only=True,evidence_sha256={str(p.relative_to(directory)):sha(p)
                        for p in sorted(target.iterdir()) if p.is_file()}))
            require(all(compare(outputs[0],v,vocabulary)['exact'] and outputs[0]==v for v in outputs),'Rank logits differ')
            native_processes=[p for p in entry['owned_processes'] if '/cluster-inference ' in p['command']]
            require(len(native_processes)==len(actual),'Process monitor did not observe every native process')
            entry.update(status='validated',peer_logits_exact=True,run_sha256=sha(directory/'run.json'),
                model_after_aggregate_sha256=verify_model(MODEL,AGGREGATE))
            previous.verify_sources(out,sources)
            require(verify_files(out/'bundle',entries)==receipt['bundle_files'],'Bundle changed after run')
            controls[name]=outputs[0]
            if distributed:receipt['matched_comparisons'].append(dict(reference=policy+'-solo',candidate=name,
                identical_policy_and_teacher=True,**compare(controls[policy+'-solo'],outputs[0],vocabulary)))
            if policy!='native':receipt['policy_departures'].append(dict(reference='native-'+partition,candidate=name,
                identical_teacher=True,quality_conclusion=False,**compare(controls['native-'+partition],outputs[0],vocabulary)))
            save();print(name,'execution/identity/peer checks passed',flush=True)
        require(len(receipt['executions'])==planned_runs,'Wrong run count')
        receipt.update(status='completed',finished_at=now(),all_execution_identity_peer_cleanup_checks_passed=True,
            model_final_aggregate_sha256=verify_model(MODEL,AGGREGATE),
            numeric_gate_failures=sum(not c['passed'] for c in receipt['matched_comparisons']),
            bundle_final_files=verify_files(out/'bundle',entries))
        save();print(json.dumps(dict(output=str(out),status=receipt['status'],logical_runs=planned_runs,
            matched_numeric_gate_failures=receipt['numeric_gate_failures'])));return 0
    except BaseException as error:
        receipt.update(status='failed',finished_at=now(),error=f'{type(error).__name__}: {error}')
        save();raise


def interrupted(signum,_frame):
    raise KeyboardInterrupt('Driver interrupted by signal '+str(signum))


if __name__=='__main__':
    for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):signal.signal(signum,interrupted)
    sys.exit(main())
