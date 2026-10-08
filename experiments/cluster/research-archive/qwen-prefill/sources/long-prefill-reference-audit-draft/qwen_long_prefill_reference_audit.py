"""CPU oracle for registered9B8192/512/1 final-only reference records.

No native/model payload reads. The caller pins actual raw natural prompt bytes.
All state geometry is derived; only offset state bytes and the complete BF16
logit row can be reconstructed. Other state digests remain opaque provenance.
"""
from __future__ import annotations
import copy
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import struct
import uuid

ROOT = Path(__file__).resolve().parent.parent
MAX_STDOUT = 16 * 1024 * 1024
MAX_PROMPT = 65536
INT_MAX = 2**63 - 1
PROFILE = 'long_prefill_8k_v1'
CONFIG_SHA = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
ARTIFACT_SHA = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
PINNED = {
 'qwen_layer_stage_recorded_audit.py': 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4',
 'qwen-layer-stage-real9b-expected-20260913.json': 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99',
 'qwen-layer-stage-plan-actual9b-20260913.json': '34bf54d8686e408cb514d9484122b1eaf27f38c2bd1cb4c2a0d0c50a95b8eb6c',
 'qwen-layer-stage-plan-verification-20260913.json': 'a75bd5a231de84ef75b637c40893e392b3874f48f7ad3e809430adbf09029cc9',
 'runs/qwen-layer-stage-prefill-ranks-serial-peer24-20260914/remote-metadata/before-config.json': CONFIG_SHA,
 'long-prefill-reference-draft/manifest.json': '55793df7791aa60ed79ac6d6a7d9b5f1eb18283514a0b5be6d9593846511b78c',
 'long-prefill-budget-draft/manifest.json': '99fd1a8568223e736e4d6bb7daee6853e7143c5f776491c2b1d725ade2fd27ca',
}
_CONTEXT = None


def require(ok, message):
    if not ok: raise ValueError(message)


def sha(data): return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def exact(actual, expected, path='value'):
    require(type(actual) is type(expected), path + ' type differs')
    if type(expected) is dict:
        require(set(actual) == set(expected), path + ' fields differ')
        for key in expected: exact(actual[key], expected[key], path + '.' + key)
    elif type(expected) is list:
        require(len(actual) == len(expected), path + ' count differs')
        for i, (a, e) in enumerate(zip(actual, expected)): exact(a, e, path + '[' + str(i) + ']')
    else: require(actual == expected, path + ' differs')


def integer(value, low=0, high=INT_MAX):
    require(type(value) is int and low <= value <= high, 'Invalid bounded integer')
    return value


def sha_string(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA256 spelling')
    return value


def read_bounded(path, maximum):
    with Path(path).open('rb') as stream: data = stream.read(maximum + 1)
    require(0 < len(data) <= maximum, 'Empty or oversized input: ' + str(path))
    return data


def check_depth(data, limit=16):
    depth, quoted, escaped = 0, False, False
    for byte in data:
        if quoted:
            if escaped: escaped = False
            elif byte == 92: escaped = True
            elif byte == 34: quoted = False
        elif byte == 34: quoted = True
        elif byte in (91, 123):
            depth += 1; require(depth <= limit, 'JSON nesting exceeds limit')
        elif byte in (93, 125):
            depth -= 1; require(depth >= 0, 'Unbalanced JSON nesting')
    require(not quoted and depth == 0, 'Incomplete JSON structure')


def verify_pins():
    found = {}
    for name, expected in PINNED.items():
        data = read_bounded(ROOT / name, 2 * 1024 * 1024)
        require(sha(data) == expected, 'Frozen dependency changed: ' + name)
        found[name] = {'sha256': expected, 'byteCount': len(data)}
    # Frozen manifests pin their own source drafts; do not require mutable
    # current repository paths to equal the historical source review.
    for manifest_name in ['long-prefill-reference-draft/manifest.json', 'long-prefill-budget-draft/manifest.json']:
        manifest = json.loads((ROOT / manifest_name).read_bytes())
        for record in manifest['files']:
            data = read_bounded(record['path'], 2 * 1024 * 1024)
            require(len(data) == record['byteCount'] and sha(data) == record['sha256'], 'Frozen draft manifest member changed')
    return found


def arithmetic_environment():
    return dict(contract='qwen_cbv2_query128_bf16_tf32_default_v1',
        requiredValues={'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'DARKBLOOM_BF16_WEIGHTS': '1', 'MLX_ENABLE_TF32': '1'},
        requiredAbsentNames=['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS'], full512TokenChunkQueryBlocks=4,
        defaultBindings={
            'MLX_METAL_GPU_ARCH': 'detect actual Metal device architecture; no override',
            'MLX_SDPA_BLOCKS': 'source default 0; native adaptive block selection',
            'MLX_ENABLE_TF32': 'explicit 1 matches pinned source default; permits eligible NAX paths',
            'DARKBLOOM_BF16_WEIGHTS': 'explicit 1 converts stored Float16 tensors to BFloat16 before subsequent arithmetic',
            'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': 'explicit 128 matches pinned source default; chunk512 uses four query blocks'},
        actualProcessEnvironmentMustBePassedBeforeMLXInitialization=True,
        sourceBinaryMetalLibraryAndHardwareIdentityStillRequired=True,
        sameChunkFullModelReferenceStillRequired=True, doesNotValidateOtherTimingOrResourceEnvironment=True,
        numericalOrPerformanceQualificationEstablished=False)


def profile_fingerprint():
    return sha('\n'.join(['qwen-stage-prefill-profile-v1', PROFILE, 'batch=1', 'prompt=1...8192',
        'chunk=1...512', 'output=1', 'teacher=0', 'frames=1...128', 'hidden=1...8192',
        'vocabulary=1...262144', 'floatingDTypes=float16,bfloat16,float32']).encode())


def resource_admission(text):
    names = dict(layers='num_hidden_layers', fullAttentionInterval='full_attention_interval', hiddenSize='hidden_size',
        queryHeads='num_attention_heads', kvHeads='num_key_value_heads', headDimension='head_dim',
        linearKeyHeads='linear_num_key_heads', linearValueHeads='linear_num_value_heads',
        linearKeyDimension='linear_key_head_dim', linearValueDimension='linear_value_head_dim', convolutionKernel='linear_conv_kernel_dim')
    g = {name: integer(text[key], 1) for name, key in names.items()}
    conv = 4 * (g['convolutionKernel'] - 1) * (2*g['linearKeyHeads']*g['linearKeyDimension'] + g['linearValueHeads']*g['linearValueDimension'])
    ssm = 4*g['linearValueHeads']*g['linearValueDimension']*g['linearKeyDimension']
    k = 4*8193*g['kvHeads']*g['headDimension']; boundary = 4*512*g['hiddenSize']
    attention = g['layers']//g['fullAttentionInterval']; recurrent = g['layers']-attention
    terms = dict(threeRecurrentGenerationsBytes=3*recurrent*(conv+ssm),
        allKVCapacityAndOffsetsBytes=attention*(2*k+4), largestSingleHostStateComponentBytes=max(conv,ssm,k),
        twoBoundaryArraysBytes=2*boundary)
    total = sum(terms.values()); require(total == 745345056 and 512*1024**2 < total <= 768*1024**2, 'Registered budget derivation differs')
    budget = dict(formula='qwen_state_snapshot_two_boundaries_f32_three_recurrent_v1', maximumTokens=8193,
        chunkSize=512, attentionLayers=attention, recurrentLayers=recurrent, convolutionBytesPerLayer=conv,
        ssmBytesPerLayer=ssm, kvCapacityBytesPerAttentionLayer=2*k, boundaryBytes=boundary, **terms,
        conservativeStateAndBoundaryBytes=total, isWholeProcessMemoryBound=False, includesWeightsOrNativeWorkspaces=False)
    return dict(qualification='registered_qwen35_9b_8192_512_bf16_v1', sourceConfigurationSHA256=CONFIG_SHA,
        expectedArtifactAggregateSHA256=ARTIFACT_SHA, promptCount=8192, chunkSize=512, outputCount=1,
        frameCount=16, batchSize=1, teacherTokenCount=0, requiredNativeDType='bfloat16', bf16ConversionRequired=True,
        geometry=g, budget=budget, namedTensorByteCeiling=768*1024**2,
        exactConfigurationBytesMatched=True, actualArtifactVerificationStillRequired=True,
        actualNativeDTypeVerificationStillRequired=True, actualPromptBytesMustBeSeparatelyPinned=True,
        independentOSResourceAdmissionStillRequired=True, numericalOrPerformanceQualificationEstablished=False,
        wholeProcessMemorySafetyEstablished=False)


def state_geometry(text):
    entries = []
    channels = 2*text['linear_num_key_heads']*text['linear_key_head_dim'] + text['linear_num_value_heads']*text['linear_value_head_dim']
    for layer in range(text['num_hidden_layers']):
        components = [('kv.keys', [1,text['num_key_value_heads'],8192,text['head_dim']], 'bfloat16'),
                      ('kv.values', [1,text['num_key_value_heads'],8192,text['head_dim']], 'bfloat16'),
                      ('kv.position_offsets',[1],'int32')] if (layer+1)%text['full_attention_interval']==0 else [
                      ('conv',[1,text['linear_conv_kernel_dim']-1,channels],'bfloat16'),
                      ('ssm',[1,text['linear_num_value_heads'],text['linear_value_head_dim'],text['linear_key_head_dim']],'float32')]
        for name, shape, dtype in components:
            entries.append(dict(globalLayerIndex=layer,component=name,shape=shape,dtype=dtype,
                                byteCount=math.prod(shape)*(2 if dtype=='bfloat16' else 4)))
    return sorted(entries,key=lambda x:(x['globalLayerIndex'],x['component']))


def context():
    global _CONTEXT
    if _CONTEXT is not None: return _CONTEXT
    pins = verify_pins()
    spec = importlib.util.spec_from_file_location('long_reference_frozen_recorded_base', ROOT/'qwen_layer_stage_recorded_audit.py')
    base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
    expected = json.loads((ROOT/'qwen-layer-stage-real9b-expected-20260913.json').read_bytes())
    config = json.loads((ROOT/'runs/qwen-layer-stage-prefill-ranks-serial-peer24-20260914/remote-metadata/before-config.json').read_bytes())
    text = config['text_config']
    require(config['model_type']=='qwen3_5' and text['num_hidden_layers']==32 and text['vocab_size']==248320, 'Wrong registered geometry')
    full = expected['fullCanonicalTensors']
    require(len(full)==927 and len({x['sourceName'] for x in full})==927, 'Incomplete canonical inventory')
    for tensor in full:
        base.parameter_bytes(tensor,'loadedDType')
        require(tensor['localName']==tensor['sourceName'], 'Full inventory changed namespace')
        dtype = 'bfloat16' if tensor['sourceDType']=='float16' else tensor['sourceDType']
        require(tensor['loadedDType']==dtype, 'Wrong stored F16-to-BF16 policy')
    total = sum(t['byteCount'] for t in full); layout = base.layout(full)
    require(total==expected['sourceModelTensorBytes'] and layout==expected['sourceParameterLayoutSHA256'], 'Independent source layout/bytes differ')
    retained = expected['sourceHeaderTensorCount']-expected['excluded']['count']
    require(retained==len(full) and expected['configurationSHA256']==CONFIG_SHA and
            expected['artifactAggregateSHA256ClaimedByPinnedManifest']==ARTIFACT_SHA, 'Source manifest/config binding differs')
    plan = json.loads((ROOT/'qwen-layer-stage-plan-actual9b-20260913.json').read_bytes())
    proof = json.loads((ROOT/'qwen-layer-stage-plan-verification-20260913.json').read_bytes())
    require(proof['status']=='passed' and proof['actual9b_standalone_exit_code']==0 and plan['configurationSHA256']==CONFIG_SHA,
            'Pure plan-control provenance differs')
    require(proof['evidence_sha256']['qwen-layer-stage-plan-actual9b-20260913.json']==PINNED['qwen-layer-stage-plan-actual9b-20260913.json'], 'Plan-control pin differs')
    require([s['mappedParameters'] for s in plan['stages']]==[463,464] and plan['mappedTextParameters']==retained, 'Plan/source coverage differs')
    plan_hash = sha(canonical(dict(adapter='qwen35-dense-two-layer-stages-v1',sourceConfigurationSHA256=CONFIG_SHA,
                                   stages=[s['fingerprint'] for s in plan['stages']])))
    require(plan_hash==plan['planSHA256'], 'Plan top fingerprint differs')
    env = arithmetic_environment(); env_hash = sha(canonical(env))
    source = dict(artifactAggregateSHA256=ARTIFACT_SHA,sourceConfigurationSHA256=CONFIG_SHA,
        sourceParameterLayoutSHA256=layout,planSHA256=plan_hash,arithmeticEnvironmentSHA256=env_hash,
        bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',sourceModelTensorBytes=total,layerCount=32,vocabularySize=248320)
    load = dict(schemaVersion=1,verifiedAggregateSHA256=ARTIFACT_SHA,configurationSHA256=CONFIG_SHA,
        sourceModelTensorBytes=total,loadedTensorBytes=total,largestHostTensorBytes=max(t['byteCount'] for t in full),
        tensorCount=len(full),sourceTensorCount=retained,parameterLayoutSHA256=layout,bf16ConversionEnabled=True)
    state = state_geometry(text)
    require(len(state)==72 and sum(e['byteCount'] for e in state)==319946784, 'Derived full-state geometry differs')
    _CONTEXT = dict(base=base,pins=pins,text=text,source=source,load=load,state=state,resource=resource_admission(text),
                    environment=env,environmentSHA256=env_hash,profileFingerprint=profile_fingerprint())
    return _CONTEXT


def prompt_tokens(data, expected_sha):
    require(type(data) is bytes and 0<len(data)<=MAX_PROMPT, 'Prompt byte bounds differ')
    require(sha(data)==sha_string(expected_sha), 'Raw prompt differs from independent caller pin')
    check_depth(data)
    def no_float(_): raise ValueError('Prompt requires integer JSON lexemes')
    def unique(pairs):
        out={}
        for key,value in pairs:
            require(key not in out,'Duplicate prompt JSON key');out[key]=value
        return out
    value=json.loads(data.decode('utf8'),object_pairs_hook=unique,parse_float=no_float,parse_constant=no_float)
    require(type(value) is list and len(value)==8192,'Prompt must contain8192 tokens')
    for token in value: integer(token,0,248319)
    return value


def request_identity(request_id, prompt):
    require(type(request_id) is str and re.fullmatch('[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}',request_id), 'Malformed request UUID')
    uid=str(uuid.UUID(request_id))
    fp=sha('\n'.join(['qwen-stage-profiled-prefill-request-v1',PROFILE,profile_fingerprint(),uid,
                      'batch=1','prompt=8192','chunk=512','output=1']).encode())
    history=sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1',PROFILE,profile_fingerprint(),fp,
                          'vocabulary=248320','prompt='+','.join(map(str,prompt)),'teacher=']).encode())
    return fp,history


def frames_and_commits(prompt):
    steps=[];commits=[]
    for i in range(16):
        frame=dict(sequence=i,phase='prefill',tokenOffset=i*512,tokenCount=512,finalPromptChunk=i==15)
        steps.append(dict(frame=frame,tokenIDs=prompt[i*512:(i+1)*512],committedTokens=(i+1)*512))
        commits.append(dict(frame=frame,committedTokens=(i+1)*512,outputKind='logits' if i==15 else 'evaluation_handle',
                            outputShape=[1,248320 if i==15 else 1],outputDType='bfloat16'))
    return steps,commits


def state_fingerprint(entries):
    material=['cbv2-owned-state-v1','tokens=8192']+[f"{e['globalLayerIndex']}|{e['component']}|{e['shape']}|{e['dtype']}|{e['byteCount']}|{e['sha256']}" for e in entries]
    return sha('\n'.join(material).encode())


def float32_bits(value):
    require(type(value) in (int,float) and math.isfinite(value),'Invalid finite Float value')
    try: packed=struct.pack('<f',value)
    except (OverflowError,struct.error) as error: raise ValueError('Float32 overflow') from error
    require(math.isfinite(struct.unpack('<f',packed)[0]),'Float32 overflow')
    return struct.unpack('<I',packed)[0]


def selection_fingerprint(s):
    f=s['frame']; b=lambda v:'true' if v else 'false'
    return sha('\n'.join(['qwen-long-prefill-reference-selection-v1',s['requestFingerprint'],s['recordedRequestFingerprint'],
        f"{f['sequence']}|{f['phase']}|{f['tokenOffset']}|{f['tokenCount']}|{b(f['finalPromptChunk'])}",
        f"tokens={s['committedTokens']}",f"vocabulary={s['vocabularySize']}",f"ordinal={s['outputOrdinal']}",
        s['policy'],s['cpuCrosscheckPolicy'],f"token={s['tokenID']}",f"ties={s['maximumTieCount']}",
        f"maximumFloat32Bits={float32_bits(s['maximumLogit'])}",f"{s['logitsShape']}|{s['logitsDType']}|{s['selectionDType']}",
        'finite='+b(s['allLogitsFinite']),'selectionMatches='+b(s['nativeSelectionMatchesCapturedFullRow'])]).encode())


def evidence_fingerprint(e):
    x=e['execution']
    return sha('\n'.join(['qwen-registered9b-long-prefill-reference-v1',e['profile'],e['profileFingerprint'],
        x['request']['fingerprint'],e['promptFileSHA256'],e['promptTokenIDsSHA256'],e['arithmeticEnvironmentSHA256'],
        sha(canonical(e['resourceAdmission'])),sha(canonical(x['source'])),sha(canonical(x['sourceLoad'])),
        sha(canonical(x['commits'])),x['finalState']['fingerprint'],x['finalLogits']['logicalBytesSHA256'],
        selection_fingerprint(x['selection'])]).encode())


def check_reference(reference, prompt_data, expected_prompt_sha256):
    c=context();prompt=prompt_tokens(prompt_data,expected_prompt_sha256)
    require(type(reference) is dict and type(reference.get('execution')) is dict,'Missing reference execution')
    x=reference['execution']; require(type(x.get('request')) is dict and type(x['request'].get('request')) is dict,'Missing profiled request')
    r=x['request'];rid=r['request'].get('requestID');simple,history=request_identity(rid,prompt)
    steps,commits=frames_and_commits(prompt)
    wanted_request=dict(request=dict(profile=PROFILE,requestID=rid,batchSize=1,promptCount=8192,chunkSize=512,outputCount=1),
        vocabularySize=248320,promptTokenIDs=prompt,teacherTokenIDs=[],steps=steps,fingerprint=history)
    exact(r,wanted_request,'request');exact(x.get('source'),c['source'],'source');exact(x.get('sourceLoad'),c['load'],'sourceLoad')
    exact(x.get('commits'),commits,'commits')
    state=x.get('finalState');require(type(state) is dict and set(state)=={'committedTokens','entries','logicalByteCount','fingerprint'},'Final state schema differs')
    exact(state['committedTokens'],8192,'state frontier');exact(state['logicalByteCount'],sum(e['byteCount'] for e in c['state']),'state bytes')
    require(type(state['entries']) is list and len(state['entries'])==72,'Final state entry count differs')
    offset_sha=sha(struct.pack('<i',8192))
    for actual,geometry in zip(state['entries'],c['state']):
        require(type(actual) is dict and set(actual)==set(geometry)|{'sha256'},'State entry fields differ')
        digest=sha_string(actual['sha256']);exact(actual,dict(geometry,sha256=digest),'state entry')
        if geometry['component']=='kv.position_offsets': require(digest==offset_sha,'Native Int32 frontier bytes differ')
    require(state_fingerprint(state['entries'])==sha_string(state['fingerprint']),'Complete state fingerprint differs')
    require(type(x.get('finalLogits')) is dict,'Missing complete logit record')
    try: raw=c['base'].logical_bytes(x['finalLogits'],248320,'bfloat16')
    except (KeyError,TypeError,OverflowError,struct.error) as error:
        raise ValueError('Malformed native logit row') from error
    values=[struct.unpack('<f',struct.pack('<I',bits[0]<<16))[0] for bits in struct.iter_unpack('<H',raw)]
    maximum=max(values);token=values.index(maximum);ties=sum(v==maximum for v in values)
    selection=x.get('selection');require(type(selection) is dict and 'maximumLogit' in selection,'Missing finite argmax selection')
    require(float32_bits(selection['maximumLogit'])==float32_bits(maximum),'Maximum logit value differs')
    wanted_selection=dict(requestFingerprint=simple,recordedRequestFingerprint=history,frame=steps[-1]['frame'],committedTokens=8192,
        vocabularySize=248320,outputOrdinal=0,policy='mlx_argmax_all_axes_with_finite_guard_v1',
        cpuCrosscheckPolicy='finite_maximum_lowest_vocabulary_index_v1',tokenID=token,maximumTieCount=ties,
        maximumLogit=selection['maximumLogit'],logitsShape=[1,248320],logitsDType='bfloat16',selectionDType='uint32',
        allLogitsFinite=True,nativeSelectionMatchesCapturedFullRow=True)
    exact(selection,wanted_selection,'selection')
    wanted_execution=dict(source=c['source'],sourceLoad=c['load'],request=wanted_request,commits=commits,selection=selection,
        finalState=state,finalLogits=x['finalLogits'],completedFrames=16,committedTokens=8192,
        perFrameStateCaptures=0,perFrameLogitCaptures=0,finalStateCaptures=1,finalLogitCaptures=1,nativeTokenSelections=1,
        allRequestStateRetired=True,intermediateNumericalStatesExported=False,candidateNumericalComparisonPerformed=False)
    # Avoid walking the complete logit row a second time; its closed schema,
    # dtype, values and exact byte hash were independently validated above.
    require(set(x)==set(wanted_execution),'Execution fields differ')
    for key in wanted_execution:
        if key not in ('finalLogits','request','commits','finalState','selection','source','sourceLoad'):
            exact(x[key],wanted_execution[key],'execution.'+key)
    wanted=dict(kind='qwen_registered9b_long_prefill_reference',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,fullModelLoads=1,freshFullModelRequests=1,stageModelsLoaded=0,
        modelReleased=True,allRequestStateRetired=True,profile=PROFILE,profileFingerprint=c['profileFingerprint'],
        promptFileSHA256=expected_prompt_sha256,promptTokenIDsSHA256=sha(','.join(map(str,prompt)).encode()),
        arithmeticEnvironment=c['environment'],arithmeticEnvironmentSHA256=c['environmentSHA256'],resourceAdmission=c['resource'],
        execution=x,fingerprint=reference.get('fingerprint'))
    require(set(reference)==set(wanted),'Reference fields differ')
    for key in wanted:
        if key not in ('execution','fingerprint'): exact(reference[key],wanted[key],'reference.'+key)
    require(evidence_fingerprint(reference)==sha_string(reference['fingerprint']),'Complete reference fingerprint differs')
    return dict(status='passed',scope='registered9b_long_prefill_8192_chunk512_output1_reference',
        promptFileSHA256=expected_prompt_sha256,promptTokenIDsSHA256=wanted['promptTokenIDsSHA256'],
        profileFingerprint=c['profileFingerprint'],requestFingerprint=simple,recordedRequestFingerprint=history,
        arithmeticEnvironmentSHA256=c['environmentSHA256'],source=c['source'],sourceTensorCount=c['load']['sourceTensorCount'],
        sourceModelTensorBytes=c['load']['sourceModelTensorBytes'],completedFrames=16,committedTokens=8192,
        finalStateComponents=72,finalStateLogicalBytes=state['logicalByteCount'],finalStateSHA256=state['fingerprint'],
        independentlyReconstructedStateOffsetComponents=8,opaqueStateComponentDigests=64,
        finalLogits={k:v for k,v in x['finalLogits'].items() if k!='values'},reconstructedNativeLogitRows=1,
        independentlyReconstructedNativeLogitBytes=len(raw),argmaxTokenID=token,maximumLogit=maximum,maximumTieCount=ties,
        referenceFingerprint=reference['fingerprint'],throughputQualified=False,physicalTransferQualified=False,
        independentModelForwardPerformed=False,allRequestStateRetiredNativeAssertion=True,modelReleasedNativeAssertion=True,
        limitations=[
            'The complete BF16 final row is reconstructed from exported Float values, including signed zeros; this checks its recorded native-byte digest, not a second model forward.',
            'All72 state shapes/dtypes/byte counts and the combined fingerprint are checked. Only eight Int32 offset digests are reconstructed; the other64 state digests expose no raw values.',
            'Actual source loading, native commits/selection/retirement/model release and early environment application remain source-bound native assertions; independent executable/archive/runtime provenance is required.',
            'The stage construction hashes are bound to the separately frozen pure Foundation plan-control receipt; Python does not reproduce Foundation config floating-number serialization.',
            'Initial resource/environment admission receipts are retained verbatim. Their pending-check flags describe admission time, while sourceLoad records the claimed completed verification.',
            'No timing, physical transport, representative workload, whole-process memory or cluster speedup is qualified.'])


def parse_rows(data):
    require(type(data) is bytes and 0<len(data)<=MAX_STDOUT,'Reference stdout exceeds bounds')
    lines=data.splitlines();require(len(lines)==2 and all(lines),'Exactly ready and terminal JSONL records are required')
    rows=[]
    for line in lines:
        check_depth(line);rows.append(context()['base'].parse_json(line.decode('utf8')))
    return rows


def validate_reports(rows,prompt_data,expected_prompt_sha256):
    require(type(rows) is list and len(rows)==2,'Exactly two outer records required')
    ready,report=rows;require(type(report) is dict and 'evidence' in report and 'memory' in report,'Missing terminal reference or memory')
    result=check_reference(report['evidence'],prompt_data,expected_prompt_sha256)
    e=report['evidence']
    exact(ready,dict(kind='qwen_long_prefill_reference_ready',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        verifiedModelLoaded=False,freshRequestStateCreated=False,profile=PROFILE,profileFingerprint=e['profileFingerprint'],
        promptFileSHA256=expected_prompt_sha256,arithmeticEnvironmentSHA256=e['arithmeticEnvironmentSHA256'],
        recordedRequestFingerprint=result['recordedRequestFingerprint']),'ready')
    memory=report['memory'];require(type(memory) is list and len(memory)==2,'Exactly two allocator observations required')
    previous_peak=0
    for item,phase in zip(memory,['before_full_model_load','full_model_released_cache_cleared']):
        require(type(item) is dict and set(item)=={'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'},'Memory observation schema differs')
        exact(item['phase'],phase,'memory phase')
        active=integer(item['activeMLXBytes']);integer(item['cachedMLXBytes']);peak=integer(item['peakMLXBytesSinceProcessStart'])
        require(peak>=active and peak>=previous_peak,'MLX peak observation is internally inconsistent');previous_peak=peak
    require(memory[-1]['cachedMLXBytes']==0,'Final native cache-clear assertion differs')
    wanted=dict(kind='qwen_long_prefill_reference_report',schemaVersion=1,completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,
        allRequestStateRetired=True,modelReleased=True,evidence=e,memory=memory)
    require(set(report)==set(wanted),'Terminal report fields differ')
    for key in wanted:
        if key not in ('evidence','memory'): exact(report[key],wanted[key],'terminal.'+key)
    result['memory']=copy.deepcopy(memory);result['allocatorObservationsAreNotRSSOrWholeProcessMemory']=True
    return result


def validate(stdout_path,prompt_path,expected_prompt_sha256):
    before=verify_pins();self_before=Path(__file__).read_bytes()
    stdout=read_bounded(stdout_path,MAX_STDOUT);prompt=read_bounded(prompt_path,MAX_PROMPT)
    result=validate_reports(parse_rows(stdout),prompt,expected_prompt_sha256)
    require(read_bounded(stdout_path,MAX_STDOUT)==stdout and read_bounded(prompt_path,MAX_PROMPT)==prompt,'Audit input changed while reading')
    require(verify_pins()==before and Path(__file__).read_bytes()==self_before,'Frozen audit dependency changed')
    result.update(stdoutSHA256=sha(stdout),stdoutByteCount=len(stdout),promptByteCount=len(prompt),
        helperSHA256=sha(self_before),frozenInputsUnchanged=True,frozenDependencyPins=before)
    return result


if __name__=='__main__':
    import sys
    require(len(sys.argv)==4,'Usage: qwen_long_prefill_reference_audit.py STDOUT PROMPT EXPECTED_PROMPT_SHA256')
    print(json.dumps(validate(*sys.argv[1:]),indent=2,sort_keys=True,allow_nan=False))
