#!/usr/bin/env python3
"""Prospective CPU short-parity replay. No model, native process or tensor reads."""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
sys.dont_write_bytecode = True
from short_parity_contract import bounded_regular, token_inputs, validate_result, PROFILES, MAX_STDOUT, same
from recorded_math import canonical, digest, logical_bytes, parse_json, require, sha_string

FIXTURE = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json')
FIXTURE_SHA = '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
INVENTORY_SHA = {'registered_qwen35_9b':'4a543a467846927736165c44a68802ad15794482ffdf3a1c60113a38c6abfb51',
                 'registered_qwen38_27b':'ebe2ded36d62a6f83bfa1c1b69951a8e24e9e63094745eb60c4bb353c8951624'}


def keys(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label+' keys differ')


def expected(profile, fixture=FIXTURE):
    require(profile in PROFILES,'Unknown profile')
    raw=bounded_regular(fixture,4*1024**2);require(digest(raw)==FIXTURE_SHA,'Retained metadata pin differs')
    item=json.loads(raw)['nine' if profile=='registered_qwen35_9b' else 'twentySeven']
    p=PROFILES[profile];config=base64.b64decode(item['configuration'],validate=True);manifest=base64.b64decode(item['manifest'],validate=True)
    require(digest(config)==p['configuration'] and digest(manifest)==p['manifest'],'Raw registered metadata differs')
    require(json.loads(manifest)['aggregate_sha256']==p['artifact'],'Artifact pin differs')
    config=json.loads(config);text=config.get('text_config',config)
    rows=sorted(item['canonicalTensors'],key=lambda x:x['name'])
    inventory='\n'.join(f'{x["name"]}|{x["sourceDType"]}|{",".join(map(str,x["shape"]))}|{x["byteCount"]}' for x in rows)
    require(digest(inventory.encode())==INVENTORY_SHA[profile],'Canonical registered inventory differs')
    require(len(rows)==p['canonicalTensorCount'] and sum(x['byteCount'] for x in rows)==p['sourceBytes'],'Registered source count/bytes differ')
    types={'U32':'uint32','F32':'float32','BF16':'bfloat16','F16':'bfloat16'}
    layout=digest('\n'.join(sorted(f'{x["name"]}:{types[x["sourceDType"]]}:{x["shape"]}' for x in rows)).encode())
    return dict(profile=profile,configuration=text,sourceParameterLayoutSHA256=layout,
                canonicalInventorySHA256=INVENTORY_SHA[profile],tensorCount=len(rows),largestTensorBytes=max(x['byteCount'] for x in rows))


def state_geometry(e, tokens):
    c=e['configuration'];out=[]
    channels=2*c['linear_num_key_heads']*c['linear_key_head_dim']+c['linear_num_value_heads']*c['linear_value_head_dim']
    for layer in range(c['num_hidden_layers']):
        if (layer+1)%c['full_attention_interval']==0:
            parts=[('kv.keys',[1,c['num_key_value_heads'],tokens,c['head_dim']],'bfloat16',2),
                   ('kv.values',[1,c['num_key_value_heads'],tokens,c['head_dim']],'bfloat16',2),
                   ('kv.position_offsets',[1],'int32',4)]
        else:
            parts=[('conv',[1,c['linear_conv_kernel_dim']-1,channels],'bfloat16',2),
                   ('ssm',[1,c['linear_num_value_heads'],c['linear_value_head_dim'],c['linear_key_head_dim']],'float32',4)]
        for component,shape,dtype,width in parts:
            out.append(dict(globalLayerIndex=layer,component=component,shape=shape,dtype=dtype,byteCount=math.prod(shape)*width))
    return sorted(out,key=lambda x:(x['globalLayerIndex'],x['component']))


def state_digest(state):
    return digest(('cbv2-owned-state-v1\ntokens='+str(state['committedTokens'])+'\n'+'\n'.join(
        f'{x["globalLayerIndex"]}|{x["component"]}|{x["shape"]}|{x["dtype"]}|{x["byteCount"]}|{x["sha256"]}' for x in state['entries'])).encode())


def frame_digest(row):
    f=row['frame'];logit=row['logits']['logicalBytesSHA256'] if 'logits' in row else 'no-logits'
    return digest(('qwen-recorded-frame-v1\n'+f'{f["sequence"]}|{f["phase"]}|{f["tokenOffset"]}|{f["tokenCount"]}|{str(f["finalPromptChunk"]).lower()}\n'
        +f'tokens={row["committedTokens"]}\n{row["outputKind"]}|{row["outputShape"]}|{row["outputDType"]}\n{row["state"]["fingerprint"]}\n{logit}').encode())


def baseline_digest(baseline):
    return digest(('qwen-layer-stage-baseline-v1\n'+baseline['request']['fingerprint']+'\n'+digest(canonical(baseline['source']))
                   +'\n'+'\n'.join(frame_digest(x) for x in baseline['frames'])).encode())


def audit(raw, profile, tokens, fixture=FIXTURE):
    outer=validate_result(raw,profile,tokens)
    # Parent's nonnumerical decoder is deliberately separate: this parser retains
    # Swift's integer spelling -0 in logit values as floating negative zero.
    first,last=[parse_json(line) for line in raw.split(b'\n')[:-1]]
    baseline=first['baseline'];comparison=last['pair']['comparison'];e=expected(profile,fixture)
    same(baseline['source']['sourceParameterLayoutSHA256'],e['sourceParameterLayoutSHA256'],'registered full layout')
    for k,v in [('sourceTensorCount',e['tensorCount']),('tensorCount',e['tensorCount']),('largestHostTensorBytes',e['largestTensorBytes'])]:
        same(first['load'].get(k),v,'full load '+k)
    sizes=[];logit_hashes=[]
    for index,frontier in enumerate([2,3,4]):
        original=baseline['frames'][index];candidate=comparison['frames'][index]
        keys(original,'frame committedTokens outputKind outputShape outputDType state'+(' logits' if index else ''),'baseline frame')
        keys(candidate,'frame committedTokens stateEntriesCompared logicalStateBytesPerSide globalStateSHA256 stateMetadataAndDigestsExact'
             +(' logits nativeLogitBytesExact' if index else ''),'comparison frame')
        state=original['state'];keys(state,'committedTokens entries logicalByteCount fingerprint','state')
        same(state['committedTokens'],frontier,'state frontier');geometry=state_geometry(e,frontier)
        require(type(state['entries']) is list and len(state['entries'])==len(geometry),'State component coverage differs')
        for entry,wanted in zip(state['entries'],geometry):
            keys(entry,'globalLayerIndex component shape dtype byteCount sha256','state entry')
            same({k:v for k,v in entry.items() if k!='sha256'},wanted,'state geometry and order')
            sha_string(entry['sha256'])
            if entry['component']=='kv.position_offsets':
                same(entry['sha256'],digest(struct.pack('<i',frontier)),'known Int32 position offset digest')
        total=sum(x['byteCount'] for x in geometry);identity=state_digest(state)
        same(state['logicalByteCount'],total,'state logical total');same(candidate['logicalStateBytesPerSide'],total,'compared total')
        same(candidate['stateEntriesCompared'],len(geometry),'compared component count')
        same(state['fingerprint'],identity,'state aggregate digest');same(candidate['globalStateSHA256'],identity,'state digest join')
        sizes.append(total)
        if index:
            left=logical_bytes(original['logits'],248320,'bfloat16');right=logical_bytes(candidate['logits'],248320,'bfloat16')
            require(left==right,'Full vocabulary native bytes differ');logit_hashes.append(digest(left))
    identity=baseline_digest(baseline)
    for value in [baseline['fingerprint'],comparison['baselineEvidenceSHA256'],last['baselineEvidenceSHA256']]:
        same(value,identity,'complete baseline evidence digest')
    return dict(kind='registered_dense_short_parity_audit',schemaVersion=1,passed=True,profile=profile,
        stdoutSHA256=digest(raw),stdoutBytes=len(raw),retainedMetadataSHA256=FIXTURE_SHA,
        canonicalInventorySHA256=e['canonicalInventorySHA256'],sourceParameterLayoutSHA256=e['sourceParameterLayoutSHA256'],
        recordedRequestFingerprint=outer['recordedRequestFingerprint'],referenceAdmissionFingerprint=outer['referenceAdmissionFingerprint'],
        baselineEvidenceSHA256=identity,frontiers=[2,3,4],stateEntriesPerFrame=len(state_geometry(e,2)),stateBytesPerFrame=sizes,
        independentlyReconstructedNativeLogitRows=4,independentlyComparedNativeLogitPairs=2,logitLogicalBytesSHA256=logit_hashes,
        signedZeroPreserved=True,fullVocabularyLogitByteParityEstablished=True,stateGeometryAndDigestBindingsReplayed=True,
        knownPositionOffsetDigestsReplayed=True,fullSourceLayoutReplayed=True,
        rawStateValueParityIndependentlyEstablished=False,loadedStageInventoryIndependentlyReaudited=False,
        nativeResourceSamplesIndependentlyAudited=False,nativeLifetimeIndependentlyObserved=False,
        planAndProfileSerializationIndependentlyReplayed=False,weightTensorValuesRead=False,
        physicalTwoMachineExecution=False,throughputMeasurementValid=False,providerEligibilityEstablished=False)


def main():
    p=argparse.ArgumentParser(description=__doc__,allow_abbrev=False)
    for flag in ['stdout','tokens-file','teacher-tokens-file','output']:p.add_argument('--'+flag,type=Path,required=True)
    for flag in ['stdout-sha256','tokens-sha256','teacher-tokens-sha256']:p.add_argument('--'+flag,required=True)
    p.add_argument('--profile',choices=PROFILES,required=True);p.add_argument('--retained-metadata',type=Path,default=FIXTURE)
    a=p.parse_args();require(a.output.parent.is_dir() and not os.path.lexists(a.output),'New audit output required')
    try:
        sha_string(a.stdout_sha256);raw=bounded_regular(a.stdout,MAX_STDOUT)
        require(digest(raw)==a.stdout_sha256,'Complete stdout pin differs')
        _,tokens=token_inputs(a.tokens_file,a.teacher_tokens_file,a.tokens_sha256,a.teacher_tokens_sha256)
        result=audit(raw,a.profile,tokens,a.retained_metadata)
    except Exception as error:
        result=dict(kind='registered_dense_short_parity_audit',schemaVersion=1,passed=False,
            expectedStdoutSHA256=a.stdout_sha256,error=type(error).__name__+': '+str(error),throughputMeasurementValid=False)
    fd=os.open(a.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as stream:json.dump(result,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(dict(passed=result['passed'],receipt=str(a.output))))
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
