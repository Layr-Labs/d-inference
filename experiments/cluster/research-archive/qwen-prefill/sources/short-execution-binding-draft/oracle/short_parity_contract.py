"""Closed short-parity outer checks; native numerical assertions remain unverified."""
from decimal import Decimal
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import uuid

BASE = Path(__file__).resolve().parent / 'stage_load_contract.py'
if hashlib.sha256(BASE.read_bytes()).hexdigest() != '8102af85633e949d53d81de605b1e8edd65792ecb47afe75cf7c5b49473e2d83':
    raise ValueError('Frozen selected-stage contract changed')
from stage_load_contract import require, bounded_regular, input_pins, power_policy, PROFILES as STAGE_PROFILES

GIB = 1024**3
MINIMUM_FREE = 6 * GIB
MAX_STDOUT, MAX_RECORD, MAX_STDERR = 64 * 1024**2, 32 * 1024**2, 65536
NATIVE_SECONDS, PARENT_SECONDS = 120, 135
PROFILES = {name:dict(value, maximumSampledRSSBytes=(8 if name == 'registered_qwen35_9b' else 20)*GIB,
                     layers=(32 if name == 'registered_qwen35_9b' else 64),
                     sourceBytes=(5038041600 if name == 'registered_qwen35_9b' else 15132802048))
            for name,value in STAGE_PROFILES.items()}


def digest(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA-256 identity')
    return value


def fingerprint(lines):
    return hashlib.sha256('\n'.join(lines).encode()).hexdigest()


def same(actual, expected, label):
    require(type(actual) is type(expected), 'Wrong type: '+label)
    if type(expected) is dict:
        require(set(actual) == set(expected), 'Wrong keys: '+label)
        for key in expected: same(actual[key],expected[key],label+'.'+key)
    elif type(expected) is list:
        require(len(actual) == len(expected), 'Wrong count: '+label)
        for i,(a,b) in enumerate(zip(actual,expected)):same(a,b,label+'['+str(i)+']')
    else: require(actual == expected, 'Wrong value: '+label)


def decode(raw):
    def obj(pairs):
        value={}
        for key,item in pairs:
            require(key not in value, 'Duplicate JSON key')
            value[key]=item
        return value
    def bad(value): raise ValueError('Nonfinite JSON: '+value)
    def finite(value):
        number=float(value);require(math.isfinite(number),'Nonfinite JSON number');return number
    return json.loads(raw,object_pairs_hook=obj,parse_constant=bad,parse_float=finite)


def token_file(path, expected_sha256, count):
    digest(expected_sha256)
    require(path.is_absolute(), 'Token path must be absolute')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <=4096, 'Expected nonempty regular <=4KiB token file')
        with os.fdopen(fd,'rb',closefd=False) as stream:raw=stream.read(4097)
        after=os.fstat(fd)
        stamp=lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        require(stamp(before)==stamp(after) and len(raw)==before.st_size,'Token file changed during read')
    finally:os.close(fd)
    require(hashlib.sha256(raw).hexdigest()==expected_sha256,'Raw token pin differs')
    ids=decode(raw)
    require(type(ids) is list and len(ids)==count and all(type(x) is int and 0<=x<248320 for x in ids),
            'Expected exact bounded integer token IDs')
    return raw,dict(sizeBytes=len(raw),sha256=expected_sha256,tokenIDs=ids)


def token_inputs(prompt_file,teacher_file,prompt_sha256,teacher_sha256):
    require(prompt_file.resolve()!=teacher_file.resolve(),'Prompt and teacher paths must differ')
    prompt,p=token_file(prompt_file,prompt_sha256,3)
    teacher,t=token_file(teacher_file,teacher_sha256,1)
    return (prompt,teacher),dict(prompt=p,teacher=t)


def native_command(executable,directory,profile,prompt_file,teacher_file,prompt_sha256,teacher_sha256):
    require(profile in PROFILES,'Unknown registered profile');digest(prompt_sha256);digest(teacher_sha256)
    return [str(executable),'--mode','qwen-dense-short-parity-check','--model-dir',str(directory),
            '--registered-dense-profile',profile,'--tokens-file',str(prompt_file),'--tokens-sha256',prompt_sha256,
            '--teacher-tokens-file',str(teacher_file),'--teacher-tokens-sha256',teacher_sha256,
            '--timeout-seconds',str(NATIVE_SECONDS)]


def check_record_bytes(raw,complete):
    require(len(raw)<=MAX_STDOUT,'Short parity stdout exceeds64MiB')
    parts=raw.split(b'\n')
    # Every native record's terminating LF counts toward its32MiB limit.
    finished=parts[:-1]
    require(len(finished)<=2 and all(0<len(p)+1<=MAX_RECORD for p in finished),'Short parity record count/32MiB bound differs')
    require(len(parts[-1])<MAX_RECORD and not (len(finished)==2 and parts[-1]),'Incomplete or extra short parity record exceeds bound')
    if complete:require(len(finished)==2 and parts[-1]==b'','Expected exactly two complete ordered records')


def live_output_bounds(path):
    # The owned child may append during this bounded read; final replay uses a
    # stable regular-file read after reaping. No JSON is trusted during execution.
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        s=os.fstat(fd);require(stat.S_ISREG(s.st_mode) and s.st_size<=MAX_STDOUT,'Invalid live stdout file')
        with os.fdopen(fd,'rb',closefd=False) as stream:raw=stream.read(MAX_STDOUT+1)
    finally:os.close(fd)
    check_record_bytes(raw,False)


GEOMETRY=dict(promptCount=3,chunkSize=2,teacherCount=1,outputCount=2,maximumTokens=5,committedFrontiers=[2,3,4])
BASE_TRUE='fullModelReleasedBeforeStageLoading verifiedFileOwnerReleased cacheClearCompleted forwardExecuted embeddingArithmeticExecuted requestStateRetired actualResourceAdmissionPerformed parentProcessFencingIndependentlyRequired correctnessOnly'.split()
BASE_FALSE='numericalParityEstablished throughputMeasurementValid providerEligibilityEstablished wholeProcessMemorySafetyEstablished'.split()
FINAL_TRUE='completed correctnessOnly numericalParityEstablished sequentialOneProcessOnly fullModelReleasedBeforeStageLoading allRequestStateRetired actualResourceAdmissionPerformed parentProcessFencingIndependentlyRequired'.split()
FINAL_FALSE='tensorValuesIndependentlyCompared throughputMeasurementValid providerEligibilityEstablished wholeProcessMemorySafetyEstablished'.split()
PAIR_TRUE='stageModelsReleased verifiedFileOwnerReleased cacheClearCompleted requestStateRetired remainingInertAllowanceRetained'.split()
BASE_KEYS=set(BASE_TRUE+BASE_FALSE+list(GEOMETRY)+['kind','schemaVersion','model','referenceAdmissionFingerprint','promptSHA256','teacherSHA256','baseline','load','budget','initialResources','releasedResources','resourceObservations','memory','runtime','fullModelsLoaded','fullCheckpointVerificationPasses'])
FINAL_KEYS=set(FINAL_TRUE+FINAL_FALSE+list(GEOMETRY)+['kind','schemaVersion','model','referenceAdmissionFingerprint','recordedRequestFingerprint','promptSHA256','teacherSHA256','baselineEvidenceSHA256','pair'])
PAIR_KEYS=set(PAIR_TRUE+['comparison','stageLoads','budget','initialResources','releasedResources','resourceObservations','memory','runtime','stageModelsLoaded','fullCheckpointVerificationPasses','physicalBufferLineageAttested'])


def envelope(row,keys,kind,profile,yes,no):
    require(type(row) is dict and set(row)==keys,'Unexpected '+kind+' envelope')
    same(row['kind'],kind,'kind');same(row['schemaVersion'],1,'schemaVersion');same(row['model'],profile,'model')
    for k in yes:same(row[k],True,k)
    for k in no:same(row[k],False,k)
    for k,v in GEOMETRY.items():same(row[k],v,k)


def validate_result(raw,profile_name,tokens):
    """Validate two-record source/history/scope joins; no state/logit arithmetic replay."""
    require(profile_name in PROFILES,'Unknown registered profile');p=PROFILES[profile_name]
    check_record_bytes(raw,True); first,last=[decode(line) for line in raw.split(b'\n')[:-1]]
    envelope(first,BASE_KEYS,'qwen_dense_short_baseline_checkpoint',profile_name,BASE_TRUE,BASE_FALSE)
    envelope(last,FINAL_KEYS,'qwen_dense_short_parity_report',profile_name,FINAL_TRUE,FINAL_FALSE)
    for k in ['fullModelsLoaded','fullCheckpointVerificationPasses']:same(first[k],1,k)
    for row in (first,last):
        same(row['promptSHA256'],tokens['prompt']['sha256'],'prompt raw pin')
        same(row['teacherSHA256'],tokens['teacher']['sha256'],'teacher raw pin')
    base=first['baseline']; require(type(base) is dict and set(base)==set('kind correctnessOnly throughputMeasurementValid request source frames fingerprint allRequestStateRetired'.split()),'Invalid complete baseline evidence')
    same(base['kind'],'qwen_layer_stage_recorded_baseline','baseline kind')
    for k,v in [('correctnessOnly',True),('throughputMeasurementValid',False),('allRequestStateRetired',True)]:same(base[k],v,k)
    req=base['request'];require(type(req) is dict and set(req)==set('request vocabularySize promptTokenIDs teacherTokenIDs steps fingerprint'.split()),'Recorded request keys differ')
    spec=req['request'];require(type(spec) is dict and set(spec)==set('requestID promptCount chunkSize outputCount'.split()),'Request spec differs')
    request_id=spec['requestID'];require(type(request_id) is str,'Missing UUID')
    canonical_uuid=str(uuid.UUID(request_id));require(request_id.lower()==canonical_uuid,'Noncanonical request UUID')
    same(spec,dict(requestID=request_id,promptCount=3,chunkSize=2,outputCount=2),'request geometry')
    geometry_fp=fingerprint(['qwen-stage-request-v1|'+canonical_uuid+'|3|2|2'])
    recorded_fp=fingerprint(['qwen-layer-stage-recorded-request-v1',geometry_fp,'vocabulary=248320',
        'prompt='+','.join(map(str,tokens['prompt']['tokenIDs'])),'teacher='+','.join(map(str,tokens['teacher']['tokenIDs']))])
    same(req['vocabularySize'],248320,'vocabulary');same(req['promptTokenIDs'],tokens['prompt']['tokenIDs'],'prompt IDs')
    same(req['teacherTokenIDs'],tokens['teacher']['tokenIDs'],'teacher IDs');same(req['fingerprint'],recorded_fp,'recorded fingerprint')
    frames=[dict(sequence=i,phase=('prefill' if i<2 else 'decode'),tokenOffset=[0,2,3][i],tokenCount=[2,1,1][i],finalPromptChunk=i==1) for i in range(3)]
    steps=[dict(frame=f,tokenIDs=ids) for f,ids in zip(frames,[tokens['prompt']['tokenIDs'][:2],tokens['prompt']['tokenIDs'][2:],tokens['teacher']['tokenIDs']])]
    same(req['steps'],steps,'recorded steps')
    source=base['source'];require(type(source) is dict,'Missing baseline source')
    plan=digest(source.get('planSHA256'));layout=digest(source.get('sourceParameterLayoutSHA256'))
    wanted_source=dict(artifactAggregateSHA256=p['artifact'],sourceConfigurationSHA256=p['configuration'],
        sourceParameterLayoutSHA256=layout,planSHA256=plan,bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',
        sourceModelTensorBytes=p['sourceBytes'],layerCount=p['layers'],vocabularySize=248320)
    same(source,wanted_source,'source identity')
    admission=fingerprint(['registered-dense-short-reference-admission-v1',profile_name,p['configuration'],p['manifest'],p['artifact'],
        plan,recorded_fp,tokens['prompt']['sha256'],tokens['teacher']['sha256'],'prompt=3|chunk=2|teacher=1|output=2|capacity=5'])
    for row in (first,last):same(row['referenceAdmissionFingerprint'],admission,'reference admission')
    same(last['recordedRequestFingerprint'],recorded_fp,'final request fingerprint')
    evidence=digest(base['fingerprint']);same(last['baselineEvidenceSHA256'],evidence,'baseline evidence join')
    load=first['load'];require(type(load) is dict,'Missing full load receipt')
    for k,v in dict(schemaVersion=1,verifiedAggregateSHA256=p['artifact'],configurationSHA256=p['configuration'],
        parameterLayoutSHA256=layout,sourceModelTensorBytes=p['sourceBytes'],loadedTensorBytes=p['sourceBytes'],
        tensorCount=p['canonicalTensorCount'],bf16ConversionEnabled=True).items():same(load.get(k),v,'full load '+k)
    pair=last['pair'];require(type(pair) is dict and set(pair)==PAIR_KEYS,'Incomplete pair report')
    for k in PAIR_TRUE:same(pair[k],True,k)
    same(pair['stageModelsLoaded'],2,'stage models');same(pair['fullCheckpointVerificationPasses'],1,'pair verification count')
    same(pair['physicalBufferLineageAttested'],False,'physical lineage claim')
    comparison=pair['comparison'];require(type(comparison) is dict and set(comparison)==set('kind correctnessOnly throughputMeasurementValid sequentialOneProcessOnly nativeBoundaryBytesCopied baselineEvidenceSHA256 requestSHA256 source stageStorageCommitmentSHA256 frames allRequestStateRetired'.split()),'Comparison evidence keys differ')
    same(comparison['kind'],'qwen_layer_stage_recorded_comparison','comparison kind')
    for k,v in [('correctnessOnly',True),('throughputMeasurementValid',False),('sequentialOneProcessOnly',True),('nativeBoundaryBytesCopied',True),('allRequestStateRetired',True)]:same(comparison[k],v,k)
    same(comparison['source'],source,'comparison source');same(comparison['requestSHA256'],recorded_fp,'comparison request')
    same(comparison['baselineEvidenceSHA256'],evidence,'comparison baseline');storage=digest(comparison['stageStorageCommitmentSHA256'])
    require(type(pair['stageLoads']) is list and len(pair['stageLoads'])==2,'Expected both stage loads')
    for i,stage in enumerate(pair['stageLoads']):
        require(type(stage) is dict,'Missing stage receipt')
        for k,v in dict(schemaVersion=1,stageIndex=i,verifiedAggregateSHA256=p['artifact'],sourceConfigurationSHA256=p['configuration'],
            planSHA256=plan,sourceParameterLayoutSHA256=layout,sourceModelTensorBytes=p['sourceBytes'],
            bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',storageCommitmentSHA256=storage).items():same(stage.get(k),v,'stage '+k)
    full_budget,pair_budget=first['budget'],pair['budget'];require(type(full_budget) is dict and type(pair_budget) is dict,'Missing budgets')
    profile_fp=digest(full_budget.get('profileFingerprint'))
    for budget,role,admission_key in [(full_budget,'fullReference','admissionFingerprint'),(pair_budget,'sequentialStagePair','referenceAdmissionFingerprint')]:
        for k,v in dict(model=profile_name,role=role,profileFingerprint=profile_fp,planFingerprint=plan,
            recordedRequestFingerprint=recorded_fp,promptSHA256=tokens['prompt']['sha256'],teacherSHA256=tokens['teacher']['sha256'],
            maximumTokens=5,resourceAdmissionPerformed=False,forwardExecuted=False).items():same(budget.get(k),v,'budget '+k)
        same(budget.get(admission_key),admission,'budget admission')
    for entries,label in [(base['frames'],'baseline'),(comparison['frames'],'comparison')]:
        require(type(entries) is list and len(entries)==3,'Incomplete '+label+' frames')
        for i,(entry,frame) in enumerate(zip(entries,frames)):
            require(type(entry) is dict,'Invalid frame');same(entry.get('frame'),frame,label+' frame')
            same(entry.get('committedTokens'),[2,3,4][i],label+' frontier')
            if label=='baseline':
                same(entry.get('outputKind'),'evaluation_handle' if i==0 else 'logits','output kind')
                same(entry.get('outputShape'),[1,1 if i==0 else 248320],'output shape')
                same(entry.get('outputDType'),'bfloat16','output dtype')
            else:
                same(entry.get('stateMetadataAndDigestsExact'),True,'native state comparison assertion')
                if i: same(entry.get('nativeLogitBytesExact'),True,'native logit comparison assertion')
                else:require('nativeLogitBytesExact' not in entry,'Intermediate logit flag must be absent')
            if i:require(type(entry.get('logits')) is dict,'Missing native full-row record')
            else:require('logits' not in entry,'Intermediate logits must be absent')
    return dict(resultRecordCount=2,resultKinds=[first['kind'],last['kind']],profileFingerprint=profile_fp,
        planFingerprint=plan,recordedRequestFingerprint=recorded_fp,referenceAdmissionFingerprint=admission,
        baselineEvidenceSHA256=evidence,nativeNumericalParityAsserted=True,outerIdentityAndScopeValidated=True,
        rawTokenHistoryIdentityReconstructed=True,independentMetadataAuditPerformed=False,
        independentNumericalAuditPerformed=False,independentTensorAuditPerformed=False,
        independentPlanSerializationReplayed=False,nativeResourceSamplesIndependentlyAudited=False)


def resource_policy(observation, profile, expected_pid=None, expected_executable=None, terminal_exit_code=None):
    require(type(observation.get('actualFreeBytes')) is int and observation['actualFreeBytes'] >= MINIMUM_FREE,
            'Actual free memory is below 6 GiB')
    require(type(observation.get('pressureLevel')) is int and 0 <= observation['pressureLevel'] <= 2,
            'Memory pressure exceeds selected-stage screen')
    require(type(observation.get('reportedSwapBytes')) is str and
            Decimal(observation['reportedSwapBytes']) == 0, 'Reported swap must be absolute zero')
    rss = observation.get('nativeRSSBytes')
    defunct = observation.get('nativeCommand') == '<defunct>'
    if defunct:
        require(type(rss) is int and rss == 0 and type(terminal_exit_code) is int,
                'Defunct sample lacks zero RSS and confirmed terminal owned process')
    if rss is not None:
        require(type(rss) is int and 0 <= rss <= profile['maximumSampledRSSBytes'],
                'Sampled native RSS exceeds selected-stage screen')
        require(type(expected_pid) is int and type(observation.get('nativePID')) is int and
                type(observation.get('nativePGID')) is int and observation['nativePID'] == expected_pid and
                observation['nativePGID'] == expected_pid, 'Sample belongs to another native process group')
        require(type(observation.get('nativeCommand')) is str and (defunct or
                observation['nativeCommand'].startswith(str(expected_executable) + ' --mode qwen-dense-short-parity-check ')),
                'Sample belongs to another native command')
