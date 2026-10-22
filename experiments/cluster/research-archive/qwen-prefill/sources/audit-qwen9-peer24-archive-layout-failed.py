#!/usr/bin/env python3
"""Independent CPU audit. Requires explicit confirmation that native runs ended."""
import argparse
import datetime
import hashlib
import itertools
import json
import math
from pathlib import Path
import re
import struct
import sys
import tarfile

sys.dont_write_bytecode = True
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
RESEARCH = Path('/Users/developer/DarkbloomDev/cluster-research')
MODEL = RESEARCH.parent / 'models/Qwen3.5-9B'
AGGREGATE = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'

def require(value, message):
    if not value: raise ValueError(message)

def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

def closed(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key: '+key)
        result[key] = value
    return result

def read(path):
    return json.loads(path.read_text(), object_pairs_hook=closed,
                      parse_constant=lambda x: require(False, 'Nonfinite JSON: '+x))

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()

def compare(left, right):
    require(len(left) == len(right) == 4, 'Expected four output rows')
    result = []
    for index, (a, b) in enumerate(zip(left, right)):
        require(len(a) == len(b) == 248320, 'Expected complete padded vocabulary')
        require(all(type(x) in (int, float) and math.isfinite(x) for x in a+b), 'Invalid logit value')
        x = [struct.unpack('<f', struct.pack('<f', n))[0] for n in a]
        y = [struct.unpack('<f', struct.pack('<f', n))[0] for n in b]
        require(all(math.isfinite(n) for n in x+y), 'Nonfinite Float32 logit')
        delta = [v-u for u, v in zip(x, y)]
        maximum = max(map(abs, delta))
        relative = math.sqrt(math.fsum(n*n for n in delta) / max(math.fsum(n*n for n in x), 1e-30))
        ax, bx = x.index(max(x)), y.index(max(y))
        result.append(dict(row=index, compared_values=len(x), differing_values=sum(u!=v for u,v in zip(x,y)),
            exact=x==y, max_absolute=maximum, relative_rms=relative, reference_argmax=ax, candidate_argmax=bx,
            argmax_equal=ax==bx, passed=maximum<.001 and relative<.0001 and ax==bx))
    return dict(exact=all(row['exact'] for row in result), json_values_exact=left==right,
        passed=all(row['passed'] for row in result), arithmetic='IEEE Float32 reconstructed from native JSON values', rows=result)

def checkpoint_metadata():
    tensors = {}
    headers = []
    for path in sorted(MODEL.glob('*.safetensors')):
        with path.open('rb') as stream:
            size = struct.unpack('<Q', stream.read(8))[0]
            require(0<size<16*1024**2, 'Invalid safetensors header size')
            raw = stream.read(size); require(len(raw)==size, 'Short safetensors header')
            header = json.loads(raw, object_pairs_hook=closed)
        headers.append(dict(path=path.name,header_bytes=size,header_sha256=hashlib.sha256(raw).hexdigest()))
        for name, tensor in header.items():
            if not name.startswith('language_model.'): continue
            require(name not in tensors, 'Duplicate text tensor')
            shape, dtype = tensor['shape'], tensor['dtype']
            lo, hi = tensor['data_offsets']; width={'BF16':2,'F16':2,'F32':4,'U32':4}[dtype]
            require(all(type(d) is int and d>0 for d in shape), 'Invalid tensor shape')
            require(type(lo) is int and type(hi) is int and 0<=lo<hi<=path.stat().st_size-size-8
                    and hi-lo==math.prod(shape)*width, 'Invalid tensor byte range')
            tensors[name]=dict(shape=shape,dtype=dtype,bytes=hi-lo,source=path.name)
    require(len(tensors)==927 and sum(t['bytes'] for t in tensors.values())==5038041600, 'Wrong registered text tensors')
    return tensors, headers

def partition_commitment(tensors, text, kind):
    """Independent explicit 9B operator-axis interpretation; no native/MLX calls."""
    hidden, intermediate = text['hidden_size'], text['intermediate_size']
    q, kv, d = text['num_attention_heads'], text['num_key_value_heads'], text['head_dim']
    key, value = text['linear_num_key_heads']*text['linear_key_head_dim'], text['linear_num_value_heads']*text['linear_value_head_dim']
    def choice(name, shape, rank):
        def axis(dim, expected, sizes=None):
            require(shape==expected, 'Unexpected registered operator tensor '+name)
            if sizes is None: sizes=[shape[dim]]
            offset=0; ranges=[]
            for size in sizes:
                require(size%2==0 and size>0, 'Unaligned two-rank axis')
                ranges.append([offset+rank*size//2,offset+(rank+1)*size//2]); offset+=size
            require(offset==shape[dim], 'Segment coverage differs')
            return dict(kind='axis',axis=dim,intervals=ranges)
        all_ = dict(kind='all',intervals=[])
        if '.layers.' not in name: return all_
        parts=name.split('.layers.',1)[1].split('.')
        layer, module, relative = int(parts[0]), parts[1], '.'.join(parts[2:])
        require(0<=layer<text['num_hidden_layers'], 'Invalid layer')
        if module in ('input_layernorm','post_attention_layernorm'):
            require(relative=='weight' and shape==[hidden], 'Bad layer norm'); return all_
        if module=='mlp':
            projection, suffix=relative.split('.'); div=8 if suffix=='weight' else 64
            require(suffix in ('weight','scales','biases'), 'Unknown FFN tensor')
            if projection in ('gate_proj','up_proj'):return axis(0,[intermediate,hidden//div])
            require(projection=='down_proj','Unknown FFN projection');return axis(1,[hidden,intermediate//div])
        if kind=='ffn': return all_
        if module=='self_attn':
            require((layer+1)%text['full_attention_interval']==0,'Attention topology differs')
            if relative in ('q_norm.weight','k_norm.weight'):
                require(shape==[d],'Attention norm width differs');return all_
            projection,suffix=relative.split('.');div=8 if suffix=='weight' else 64
            require(suffix in ('weight','scales','biases'),'Unknown attention tensor')
            if projection=='o_proj':return axis(1,[hidden,q*d//div])
            require(projection in ('q_proj','k_proj','v_proj'),'Unknown attention projection')
            return axis(0,[q*d*2 if projection=='q_proj' else kv*d,hidden//div])
        require(module=='linear_attn' and (layer+1)%text['full_attention_interval']!=0,'GDN topology differs')
        if relative=='norm.weight':
            require(shape==[text['linear_value_head_dim']],'GDN norm width differs');return all_
        if relative in ('A_log','dt_bias'):return axis(0,[text['linear_num_value_heads']])
        if relative=='conv1d.weight':return axis(0,[2*key+value,text['linear_conv_kernel_dim'],1],[key,key,value])
        projection,suffix=relative.split('.');div=8 if suffix=='weight' else 64
        require(suffix in ('weight','scales','biases'),'Unknown GDN tensor')
        if projection=='out_proj':return axis(1,[hidden,value//div])
        if projection=='in_proj_qkv':return axis(0,[2*key+value,hidden//div],[key,key,value])
        if projection=='in_proj_z':return axis(0,[value,hidden//div])
        require(projection in ('in_proj_a','in_proj_b'),'Unknown GDN projection')
        return axis(0,[text['linear_num_value_heads'],hidden//div])
    sources=[];layouts=[[],[]];total=ffn=sharded=0;loaded=[0,0];selected=[0,0];largest=[0,0]
    for name,tensor in sorted(tensors.items()):
        shape=tensor['shape'];dtype={'BF16':'bfloat16','F16':'float16','F32':'float32','U32':'uint32'}[tensor['dtype']]
        loaded_dtype='bfloat16' if dtype=='float16' else dtype
        selections=[choice(name,shape,rank) for rank in (0,1)]
        is_ffn='.mlp.' in name;is_sharded=selections[0]['kind']=='axis'
        total+=tensor['bytes'];ffn+=tensor['bytes'] if is_ffn else 0;sharded+=tensor['bytes'] if is_sharded else 0
        for rank,s in enumerate(selections):
            outshape=list(shape)
            if is_sharded:outshape[s['axis']]=sum(hi-lo for lo,hi in s['intervals'])
            count=tensor['bytes']*math.prod(outshape)//math.prod(shape)
            loaded[rank]+=count;selected[rank]+=count if is_sharded else 0;largest[rank]=max(largest[rank],count)
            layouts[rank].append(f'{name}:{loaded_dtype}:{outshape}')
        sources.append(dict(name=name,shape=shape,sourceDType=dtype,loadedDType=loaded_dtype,byteCount=tensor['bytes'],
                            isFeedForward=is_ffn,rankSelections=selections))
    result=dict(schemaVersion=1,sourceTensorManifestSHA256=hashlib.sha256(canonical(sources)).hexdigest(),
        sourceModelTensorBytes=total,sourceFFNTensorBytes=ffn,sourceShardedFFNTensorBytes=ffn,sourceShardedTensorBytes=sharded,
        ranks=[dict(rank=rank,parameterLayoutSHA256=hashlib.sha256('\n'.join(layouts[rank]).encode()).hexdigest(),
                    loadedTensorBytes=loaded[rank],selectedShardedTensorBytes=selected[rank]) for rank in (0,1)])
    return result,largest

PACKAGE = RESEARCH / 'qwen9-peer24-package-20260913'
PACKAGE_SHA = '49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76'
ARCHIVE_SHA = '901dc501d596dd238f67d24693ca9b01af8245019337a4e62dd4610d6b112fa4'
ARCHIVE_BYTES = 569425201

def verify_package(evidence):
    require(sha(PACKAGE/'package-manifest.json')==PACKAGE_SHA,'Package manifest differs')
    manifest=read(PACKAGE/'package-manifest.json')
    seen=set()
    for entry in manifest['files']:
        name=entry['path'];p=PACKAGE/name
        require(name not in seen and not Path(name).is_absolute() and '..' not in Path(name).parts,'Invalid package path')
        require(p.is_file() and not p.is_symlink() and p.resolve().is_relative_to(PACKAGE.resolve()),'Package file escapes')
        require(p.stat().st_size==entry['size_bytes'] and sha(p)==entry['sha256'],'Changed package '+name)
        seen.add(name);evidence[str(p)]=entry['sha256']
    require(seen=={str(p.relative_to(PACKAGE)) for p in PACKAGE.rglob('*') if p.is_file()}-{'package-manifest.json'},'Extra package files')
    require(not any(p.is_symlink() for p in PACKAGE.rglob('*')),'Package symlink')
    require(len(seen)==164,'Wrong portable package size')
    origin=manifest['origin'];prior=RESEARCH/'runs/qwen9-local-tp-full-20260913'
    require(sha(PACKAGE/'origin/receipt.json')==origin['receipt_sha256']==sha(prior/'receipt.json'),'Package origin differs')
    require(sha(PACKAGE/'source-manifest.json')==origin['source_manifest_sha256'],'Source manifest pin differs')
    require(sha(PACKAGE/'bundle/cluster-inference')==origin['binary_sha256'],'Binary pin differs')
    require(sha(PACKAGE/'bundle/bundle.json')==origin['bundle_manifest_sha256'],'Bundle pin differs')
    pins=manifest['pins']
    require(pins==dict(aggregate_sha256=AGGREGATE,config_sha256=CONFIG,prompt_tokens=96,output_tokens=4,chunk_size=32,
        teacher_tokens=[4087,13,271],execution_path='cbv2-contiguous',default_plans=['solo','ffn','full'],policies=['native','both-wide']), 'Package workload differs')
    # Frozen drivers must be exact original files; only separately hashed wrapper
    # replaces filesystem roots and source archival callbacks (reviewed offline).
    for name in ('validate-qwen9-local-tp.py','qwen9_local_tp_support.py','validate-qwen9-output-boundaries.py'):
        require(sha(PACKAGE/'drivers'/name)==sha(prior/name),'Original driver changed '+name)
    evidence[str(PACKAGE/'package-manifest.json')]=PACKAGE_SHA
    return manifest

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--confirmed-terminal',action='store_true')
    parser.add_argument('--package-only',action='store_true')
    parser.add_argument('--run',type=Path,default=RESEARCH/'runs/qwen9-peer24-20260913/run')
    args=parser.parse_args();evidence={};package=verify_package(evidence)
    if args.package_only:
        print(json.dumps(dict(package_files=164,manifest_sha256=PACKAGE_SHA,package_verified=True)));return
    require(args.confirmed_terminal,'Require root confirmation of terminal execution and complete extraction')
    archive=RESEARCH/'qwen9-peer24-results-20260913.tar.gz'
    require(archive.stat().st_size==ARCHIVE_BYTES and sha(archive)==ARCHIVE_SHA,'Transferred archive bytes differ')
    evidence[str(archive)]=ARCHIVE_SHA
    base=args.run;archive_entries=[];archive_paths=set()
    with tarfile.open(archive,'r|gz') as stream:
        for member in stream:
            relative=Path(member.name)
            require(not relative.is_absolute() and '..' not in relative.parts and relative.parts[0]=='run'
                and member.name not in archive_paths and (member.isdir() or member.isfile()),'Unsafe archive entry')
            archive_paths.add(member.name);target=base.parent/relative
            if member.isfile():
                with stream.extractfile(member) as content: digest=hashlib.file_digest(content,'sha256').hexdigest()
                require(target.is_file() and not target.is_symlink() and target.stat().st_size==member.size
                    and sha(target)==digest,'Extraction differs '+member.name)
                evidence[str(target)]=digest
                archive_entries.append(dict(path=member.name,size_bytes=member.size,sha256=digest))
            else: require(target.is_dir(),'Missing archive directory')
    require(len(archive_paths)==358,'Archive entry count differs')
    receipt=read(base/'receipt.json')
    require(receipt['status']=='completed','Native run receipt is not successfully terminal; do not inspect large outputs')
    require(receipt['requested_subset']=='all' and receipt['planned_logical_runs']==6
            and receipt['selected_partitions']==['solo','ffn','full'],'Wrong selected subset')
    require(len(receipt['executions'])==6 and receipt['all_execution_identity_peer_cleanup_checks_passed'] is True,'Incomplete execution')
    for flag in ('hardware_throughput_qualification','numerical_qualification','model_quality_qualification'):
        require(receipt[flag] is False,'Unexpected qualification claim')
    def check(path,expected=None):
        digest=sha(path);require(expected is None or digest==expected,'Changed evidence '+str(path))
        evidence[str(path)]=digest;return digest
    check(base/'receipt.json')
    portable=read(base/'portable-execution.json');check(base/'portable-execution.json')
    require(portable['package_manifest_sha256']==PACKAGE_SHA and portable['package_unchanged_after'] is True
        and portable['driver_receipt_sha256']==sha(base/'receipt.json') and portable['driver_return_code']==0
        and portable['git_checkout_used'] is False and portable['selected_plans']=='all'
        and portable['planned_logical_runs']==6 and portable['origin']==package['origin'],'Portable execution differs')
    for name in ('run-qwen9-staged-local-tp.py','qwen9_staged_package.py'):
        check(base/name,sha(PACKAGE/'drivers'/name))
    require(portable['wrapper_sha256']==sha(base/'run-qwen9-staged-local-tp.py'),'Wrapper differs')
    inspection=read(RESEARCH/'qwen9-peer24-readonly-inspection-20260913.json')
    check(RESEARCH/'qwen9-peer24-readonly-inspection-20260913.json')
    require(inspection['cpu']=='Apple M4 Pro' and inspection['physical_memory_bytes']==25769803776
        and portable['python_executable_sha256']==inspection['python_executable_sha256'],'Peer identity differs')
    check(base/'source-manifest.json',receipt['source_manifest_sha256'])
    changed=[];sources=read(base/'source-manifest.json')
    for entry in sources:
        p=base/'source'/entry['path'];require(p.stat().st_size==entry['size_bytes'],'Source size differs')
        check(p,entry['sha256'])
        if sha(REPO/entry['path'])!=entry['sha256']:changed.append(entry['path'])
    require(all(name.endswith('.md') for name in changed),'Executable source changed since snapshot')
    for name,digest in receipt['driver_files_sha256'].items():check(base/name,digest)
    sys.path.insert(0,str(base/'source/experiments/cluster'))
    from runtime.artifacts import verify_model,verify_files
    from runtime.reports import reports
    from runtime.configuration import validate
    require(verify_model(MODEL,AGGREGATE)==receipt['model_final_aggregate_sha256']==receipt['model_before_aggregate_sha256'],'Artifact differs')
    check(MODEL/'config.json',CONFIG)
    check(base/'model-manifest.json',receipt['model_manifest_sha256'])
    require(sha(MODEL/'manifest.json')==receipt['model_manifest_sha256'],'Saved manifest differs')
    check(base/'bundle/bundle.json',receipt['bundle_manifest_sha256'])
    bundle=read(base/'bundle/bundle.json')['files']
    require(verify_files(base/'bundle',bundle)==receipt['bundle_files']==receipt['bundle_final_files'],'Bundle differs')
    current=REPO/'experiments/cluster/inference/.build/arm64-apple-macosx/release/cluster-inference'
    check(current,receipt['binary_sha256'])
    prior=RESEARCH/'runs/qwen9-output-boundaries-20260913'
    local=RESEARCH/'runs/qwen9-local-tp-full-20260913'
    check(prior/'receipt.json',receipt['input_receipt_sha256'])
    for name,digest in receipt['input_files_sha256'].items():check(base/name,digest);check(prior/name,digest)
    prompt,teacher=read(base/'prompt-96.json'),read(base/'baseline-teacher.json')
    require(len(prompt)==96 and teacher==[4087,13,271],'Wrong input history')
    require(hashlib.sha256(json.dumps(prompt,separators=(',',':')).encode()).hexdigest()
            =='4c1f00887775d26c29e398bc54e2b37501614599455df2f3b83c5544608b3612','Prompt identity differs')
    text=read(MODEL/'config.json')['text_config'];tensors,headers=checkpoint_metadata()
    saved_inventory=read(base/'tensor-inventory.json')
    require(saved_inventory==receipt['inventory'] and headers==saved_inventory['files'],'Header inventory differs')
    require(hashlib.sha256(canonical(tensors)).hexdigest()==saved_inventory['metadata_sha256'],'Text metadata differs')
    commitments={kind:partition_commitment(tensors,text,kind) for kind in ('ffn','full')}
    require([commitments[k][0]['ranks'][0]['loadedTensorBytes'] for k in ('ffn','full')]
        ==[3679087104,3091423488],'Unexpected rank loaded payload')
    require(all(v[1]==[508559360]*2 for v in commitments.values()),'Unexpected largest selected tensor')
    outputs={};runs=[];hook_total=0
    for entry in receipt['executions']:
        name=entry['name'];partition=name.rsplit('-',1)[1];distributed=partition!='solo';world=2 if distributed else 1
        commitment,largest=commitments[partition] if distributed else (None,None)
        require(entry['status']=='validated' and entry['exit_code']==0,'Incomplete native call')
        require(entry['cleanup']['all_observed_owned_processes_exited'] and entry['cleanup']['launcher_reaped'],'Missing cleanup evidence')
        require(entry['preflight']['passed'] and not entry['postflight']['severe_pressure'],'Admission/pressure failed')
        samples=entry['memory_samples'];require(samples,'Missing memory samples')
        require(all(sample['physical_bytes']==25769803776 and sample['memory_pressure_level']==1
            and sample['swap_used_bytes']==0 and not sample['severe_pressure'] for sample in samples),'Peer memory state differs')
        require(entry['preflight']['swap_used_bytes']==entry['postflight']['swap_used_bytes']==0,'Peer swap was not zero')
        require(entry['peak_observed_owned_rss_bytes']>=max(sample['owned_process_rss_bytes'] for sample in samples),'RSS peak lower than samples')
        native_processes=[x for x in entry['owned_processes'] if '/cluster-inference ' in x['command']]
        supervisors=[x for x in entry['owned_processes'] if '/rank_worker.py ' in x['command']]
        require(len(native_processes)==len(supervisors)==world,'Not every owned worker observed')
        require(len({x['pid'] for x in entry['owned_processes']})==len(entry['owned_processes']),'Duplicate owned process')
        require(entry['cleanup']==dict(all_observed_owned_processes_exited=True,launcher_reaped=True,cancel_files_requested=False), 'Cleanup was not clean ordinary completion')
        require(entry['model_before_aggregate_sha256']==entry['model_after_aggregate_sha256']==AGGREGATE,'Per-call artifact differs')
        for channel in ('stdout','stderr'):check(base/(name+'-launcher')/(channel+'.txt'),entry[channel+'_sha256'])
        check(base/(name+'.spec.json'),entry['spec_sha256']);directory=base/name
        check(directory/'run.json',entry['run_sha256']);run=read(directory/'run.json')
        spec=validate(read(base/(name+'.spec.json')))
        require(run['spec']==spec and run['exit_codes']==[0]*world and run['verified_execution'] is True
                and run['hardware_throughput_candidate'] is False and run['cancellation_reason'] is None,'Invalid run identity')
        require(spec['workload']['prompt_ids']==prompt and spec['workload']['teacher_tokens']==teacher,'Wrong consumed input')
        require(spec.get('local_correctness',False)==distributed and len(spec['ranks'])==world,'Opt-in changed')
        ranks=[dict(rank,local=str(directory/f"rank-{rank['rank']}")) for rank in run['ranks']]
        require(reports(ranks,spec)==run['reports'],'Native report validation differs')
        check(directory/'bundle/bundle.json',receipt['bundle_manifest_sha256'])
        require(verify_files(directory/'bundle',bundle)==receipt['bundle_files'],'Staged bundle differs')
        peer=[];rank_summary=[]
        for rank,record in enumerate(run['reports']):
            require(record['configurationSHA256']==CONFIG and record['executionPath']=='cbv2-contiguous'
                and record['vocabularySize']==248320 and record['modelFamily']=='qwen35'
                and record['feedForwardKind']=='dense' and record['syntheticWeights'] is False
                and record['mtpEnabled'] is False and record['bf16ConversionEnabled'] is True
                and record['embeddingActivationDType']=='bfloat16' and record['ffnScaleDTypes']==['bfloat16'],'Wrong real model identity')
            precision='float32' if name.startswith('both-wide') else 'native'
            require(record['attentionOutputPrecision']==record['ffnOutputPrecision']==precision,'Wrong arithmetic policy')
            saved=entry['ranks'][rank];target=directory/f'rank-{rank}'
            for filename,digest in saved['evidence_sha256'].items():check(directory/filename,digest)
            check(target/'logits.json',saved['logits_sha256'])
            rank_config=read(target/'rank.json');argv=rank_config['arguments']
            require(argv.count('--local-correctness')==int(distributed),'Missing or duplicated opt-in flag')
            if distributed:
                require(argv.count('--artifact-aggregate-sha256')==1
                        and argv[argv.index('--artifact-aggregate-sha256')+1]==AGGREGATE,'Expected aggregate absent from argv')
                require(record['partition']==partition and record['worldSize']==2 and record['rank']==rank
                    and record['correctnessOnly'] is True and record['throughputMeasurementValid'] is False,'TP mode misclassified')
                require(record['partitionStorage']==commitment,'Exact source selections/layout commitment differs')
                direct=record['directShardLoad']
                require(direct['verifiedAggregateSHA256']==AGGREGATE and direct['sourceTensorCount']==direct['tensorCount']==927
                    and direct['largestHostTensorBytes']==largest[rank],'Direct source/host accounting differs')
            result=record['runs'][0]
            require(result['decodeInputTokens']==teacher and result['decodeForwardCount']==3,'Wrong history/forward count')
            values=read(target/'logits.json');compare(values,values)
            require([row.index(max(row)) for row in values]==result['localArgmaxTokens'],'Logits/local argmax disagree')
            peer.append(values)
            logs=(target/'stderr.log').read_text().splitlines()
            hook=[re.fullmatch(r'CBv2 model reduction hooks verified: (\d+) across (\d+) forwards',line) for line in logs]
            hook=[m for m in hook if m]
            require(len(hook)==int(distributed),'Missing or duplicate graph-hook receipt')
            if distributed:
                expected_hooks=384 if partition=='full' else 192
                require(tuple(map(int,hook[0].groups()))==(expected_hooks,6),'Incorrect graph-hook count');hook_total+=expected_hooks
            startup=[json.loads(line.removeprefix('local-correctness-load-memory: ')) for line in logs
                     if line.startswith('local-correctness-load-memory: ')]
            require(startup==saved['startup_loading_mlx_observation'] and len(startup)==int(distributed),'Loading memory evidence differs')
            rank_summary.append(dict(rank=rank,generated_tokens=result['generatedTokens'],local_argmax=result['localArgmaxTokens'],
                execution_peak_mlx_bytes=result['peakMLXBytes'],execution_active_mlx_bytes=result['activeMLXBytes'],
                startup_loading_mlx=startup,local_correctness=distributed,
                parameter_layout_sha256=record['parameterLayoutSHA256'],partition_plan_sha256=record.get('partitionPlanSHA256')))
        require(all(value==peer[0] for value in peer),'Peer logits not byte-equivalent as serialized numeric values')
        outputs[name]=peer[0]
        runs.append(dict(name=name,rank_count=world,peer_logits_exact=True,ranks=rank_summary,
            peak_observed_owned_rss_bytes=entry['peak_observed_owned_rss_bytes'],memory_samples=len(entry['memory_samples']),
            sampled_pressure_levels=sorted({sample['memory_pressure_level'] for sample in entry['memory_samples']}),
            observed_swap_increase_bytes=entry['postflight']['swap_used_bytes']-entry['preflight']['swap_used_bytes'],
            observed_processes_exited=entry['cleanup']['all_observed_owned_processes_exited'],
            cleanup=entry['cleanup'],preflight=entry['preflight'],postflight=entry['postflight']))
    matched=[];departures=[]
    for policy,part in itertools.product(('native','both-wide'),('ffn','full')):
        result=dict(reference=policy+'-solo',candidate=policy+'-'+part,identical_policy_and_teacher=True,
                    **compare(outputs[policy+'-solo'],outputs[policy+'-'+part]))
        require(result==next(x for x in receipt['matched_comparisons'] if x['candidate']==result['candidate']),'Matched comparison differs')
        matched.append(result)
    for part in ('solo','ffn','full'):
        result=dict(reference='native-'+part,candidate='both-wide-'+part,identical_teacher=True,quality_conclusion=False,
                    **compare(outputs['native-'+part],outputs['both-wide-'+part]))
        require(result==next(x for x in receipt['policy_departures'] if x['reference']==result['reference']),'Policy departure differs')
        departures.append(result)
    local_receipt=read(local/'receipt.json');check(local/'receipt.json',package['origin']['receipt_sha256'])
    cross_hardware=[]
    for name in ('native-solo','native-full','both-wide-solo','both-wide-full'):
        previous=next(x for x in local_receipt['executions'] if x['name']==name)
        file=local/name/'rank-0/logits.json';check(file,previous['ranks'][0]['logits_sha256'])
        comparison=compare(read(file),outputs[name])
        require(comparison['exact'] and comparison['json_values_exact'],'Cross-hardware values differ '+name)
        require(sha(file)==sha(base/name/'rank-0/logits.json'),'Cross-hardware serialized capture differs '+name)
        cross_hardware.append(dict(name=name,serialized_file_bytes_exact=True,**comparison))
    prior_receipt=read(prior/'receipt.json');regressions=[]
    for current,old in [('native-solo','cbv2-native'),('both-wide-solo','cbv2-attention-ffn-float32')]:
        old_entry=next(x for x in prior_receipt['native_calls'] if x['name']==old)
        file=prior/old/'rank-0/logits.json';check(file,old_entry['logits_sha256'])
        comparison=compare(read(file),outputs[current])
        require(comparison['exact'] and comparison['json_values_exact'],'Prior solo regression failed')
        regressions.append(dict(current=current,prior=old,**comparison))
    require(receipt['numeric_gate_failures']==sum(not x['passed'] for x in matched),'Failure count differs')
    improvements=[]
    for part in ('ffn','full'):
        native=next(x for x in matched if x['candidate']=='native-'+part)
        wide=next(x for x in matched if x['candidate']=='both-wide-'+part)
        improvements.append(dict(partition=part,rows=[dict(row=i,native_relative_rms=a['relative_rms'],both_wide_relative_rms=b['relative_rms'],
            relative_rms_reduction_percent=(1-b['relative_rms']/a['relative_rms'])*100)
            for i,(a,b) in enumerate(zip(native['rows'],wide['rows']))]))
    token_boundary={name:{str(token):rows[0][token] for token in (4087,10926)} for name,rows in outputs.items()}
    audit=dict(schema_version=1,status='passed',audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        audit_script_sha256=sha(Path(__file__)),scope='CPU audit only; no native/GPU/process launch or transport operation',
        run_directory=str(base),logical_runs=6,rank_reports=10,logit_rows=40,logit_values=9932800,source_files=len(sources),changed_documentation_paths=changed,
        artifact_aggregate_sha256=AGGREGATE,model_file_count=12,model_bytes=6113952230,
        artifact_evidence_scope='Local exact artifact payload independently rehashed; remote artifact before/after aggregate checks are saved driver receipts bound to unchanged verifier code, not a second remote filesystem read.',
        native_binary_sha256=receipt['binary_sha256'],source_manifest_sha256=receipt['source_manifest_sha256'],
        model_storage_reconstructed_from_actual_headers={k:v[0] for k,v in commitments.items()},
        largest_selected_host_tensor_bytes={k:v[1] for k,v in commitments.items()},
        portable_package=dict(manifest_sha256=PACKAGE_SHA,files=164,execution=portable),
        cross_hardware_comparisons=cross_hardware,hardware_inspection=inspection,
        archive_entries_verified=358,archive_regular_files_verified=len(archive_entries),
        archive_file_manifest_sha256=hashlib.sha256(canonical(archive_entries)).hexdigest(),
        runs=runs,matched_comparisons=matched,policy_departures=departures,prior_solo_regressions=regressions,
        wider_policy_relative_error_change=improvements,first_row_token_boundary=token_boundary,
        graph_hook_total=hook_total,graph_hook_semantics='192 FFN or 384 full reductions across 6 forwards per rank; aggregate graph-hook accounting, not a transport timing proof',
        conclusions=dict(matched_strict_passes=sum(x['passed'] for x in matched),matched_comparisons=4,
            peer_logit_equality=True,prior_solo_regressions_exact=True,
            matched_argmax_disagreements=sum(not row['argmax_equal'] for x in matched for row in x['rows']),
            throughput_qualified=False,model_quality_qualified=False,physical_two_machine_execution=False,ffn_plan_executed=True,cross_hardware_matching_modes_exact=True),
        memory_limits='Stored payload caps and sampled memory admission are not a whole-process hard cap. Startup MLX and post-load-reset execution peaks are distinct; RSS/pressure samples may miss short transients.',
        evidence_sha256=evidence)
    require(hook_total==2304,'Unexpected combined graph-hook count')
    output=base/'independent-cpu-audit.json';output.write_text(json.dumps(audit,indent=2)+'\n')
    print(json.dumps(audit['conclusions']));print(output)

if __name__=='__main__': main()
