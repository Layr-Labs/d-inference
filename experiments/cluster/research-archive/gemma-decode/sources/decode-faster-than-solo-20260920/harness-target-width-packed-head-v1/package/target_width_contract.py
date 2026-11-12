"""Strict execution schema; complete numerical equality is replayed after retirement."""
import hashlib
import re
from binding_common import require

POLICY='gemma4_verification_packed_m1_dense_packed_head_v1'
MODES=('ordinary','verificationOne','verificationThreeKeepThree','verificationThreeKeepOne')
ROW_ORDINALS=(0,1,2,3,4,15)
FLAGS=dict(nativeExecuted=True,modelReleased=True,assistantLoaded=False,assistantForwardExecuted=False,
    sameBuildReferenceCreated=True,targetVerificationEnabled=True,numericalComparisonPerformed=False,
    targetBatchNumericsQualified=False,performanceMeasurement=False,performanceQualified=False,
    runtimeServingEnabled=False,encryptedRDMAEstablished=False,physicalProcessOrLeaseRetirementEstablished=False,
    collectiveCreated=False,collectiveReleased=False)
FIELDS=set(FLAGS)|{'denseProjection','schema','benchmarkJob','ordinaryInputScopeSHA256','scopeSHA256','planSHA256','sourceLoad',
    'referenceRequestID','referenceRequestSHA256','referenceSelectedTokenIDs','referenceSelectedTokenIDsSHA256',
    'modes','samples','resources','targetResources','files','diagnosticRequests','referenceRequests','comparisonRequests',
    'checkpointFrontier','rowsPerRequest','stateComponentsPerRequest','allActualTargetArgmaxMatchReference',
    'nativeCacheBytesAfterRelease','guardMetrics','guardObservationPolicy'}
SAMPLE_FLAGS=dict(assistantForwardExecuted=False,requestStateRetired=True,finalCommittedTokens=143,
    checkpointCapturedBeforeRequestRetirement=True,numericalQualificationPassed=False,performanceMeasurement=False)
SAMPLE_FIELDS=set(SAMPLE_FLAGS)|{'projectionPolicy','ordinal','requestID','ordinaryRequestScopeSHA256','mode','requestSHA256',
    'forcedInputSequence','actualTargetArgmax','expectedGreedyIDs','allArgmaxMatchReference','checkpointFrontier',
    'rows','checkpointState','binding','referenceGeneratedInThisSession','teacherForcedInputs'}

def integer(value,low=0):return type(value) is int and low<=value<2**63
def hashed(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None
def token_hash(ids):return hashlib.sha256(','.join(map(str,ids)).encode()).hexdigest()
def text_hash(parts):return hashlib.sha256('\n'.join(parts).encode()).hexdigest()
def file_record(value):
    require(type(value) is dict and set(value)=={'name','bytes','sha256'}
        and type(value['name']) is str and re.fullmatch('[a-z0-9_.-]{1,128}',value['name'])
        and not value['name'].startswith('.') and integer(value['bytes'],1)
        and value['bytes']<=64*1024**2 and hashed(value['sha256']),'Width sidecar record')

def validate_terms(rows):
    require(type(rows) is list and len(rows)<=180,'Width resource term bound')
    names=set()
    for row in rows:
        require(set(row)=={'name','logicalBytes','allocationBound'} and type(row['name']) is str
            and 1<=len(row['name'])<=160 and row['name'] not in names
            and integer(row['logicalBytes'],1) and integer(row['allocationBound'],row['logicalBytes']),
            'Width independently bounded resource term')
        names.add(row['name'])
    return sum(x['allocationBound'] for x in rows)

def validate_result(value,job):
    require(type(value) is dict and set(value)==FIELDS,'Width result fields')
    require(value['denseProjection']==dict(policy=POLICY,expectedDenseModules=235,expectedTiedHeads=1,
        serialHeadLogicalBytes=4*1024**2,gatheredOverrideEnabled=False,singleRowOverrideEnabled=False,
        wholeModelNumericsQualified=False),'Dense projection policy/actual complete module coverage')
    dense=value['denseProjection']
    require(all(type(dense[k]) is int for k in ('expectedDenseModules','expectedTiedHeads','serialHeadLogicalBytes'))
        and all(dense[k] is False for k in ('gatheredOverrideEnabled','singleRowOverrideEnabled','wholeModelNumericsQualified')),
        'Dense policy integer and false-flag types')
    require(value['schema']=='gemma4_target_width_qualification_result_v1' and value['benchmarkJob']==job,
        'Width result/job identity')
    require((job['mode'],job['promptCount'],job['chunkSize'],job['outputCount'],job['cut'],job['prefillPolicy'],job['residualDType'])
        ==('full',128,64,16,7,'serial','bfloat16') and job['captureEvidence'] is True,'Width workload')
    for k,want in FLAGS.items():require(value[k] is want,'Width flag '+k)
    require([value[k] for k in ('diagnosticRequests','referenceRequests','comparisonRequests','checkpointFrontier',
        'rowsPerRequest','stateComponentsPerRequest')]==[4,1,3,132,6,90]
        and value['modes']==list(MODES) and value['nativeCacheBytesAfterRelease']==0,'Width scope counts')
    require(value['guardObservationPolicy']=='gemma4_invocation_fresh_observation_v1'
        and value['guardMetrics']['schema']=='gemma4_guard_wall_counters_v1'
        and value['guardMetrics']['overflow'] is False,'Width original guard policy')
    require(all(hashed(value[k]) for k in ('ordinaryInputScopeSHA256','scopeSHA256','planSHA256','referenceRequestSHA256',
        'referenceSelectedTokenIDsSHA256')),'Width identity')
    reference=value['referenceSelectedTokenIDs']
    require(type(reference) is list and len(reference)==16 and all(integer(x) and x<262144 for x in reference)
        and token_hash(reference)==value['referenceSelectedTokenIDsSHA256'],'Width actual reference packet')
    require(type(value['samples']) is list and len(value['samples'])==4,'Width four actual requests')
    expected_files=[]
    for ordinal,sample in enumerate(value['samples']):
        require(type(sample) is dict and set(sample)==SAMPLE_FIELDS,'Width sample fields')
        require(sample['projectionPolicy']==('ordinary_m1_bypass' if ordinal<2 else POLICY),
            'Dense hook must leave actual ordinary reference and width1 control unmodified')
        for k,want in SAMPLE_FLAGS.items():
            require(sample[k] is want if type(want) is bool else type(sample[k]) is int and sample[k]==want,'Width sample flag '+k)
        require(sample['ordinal']==ordinal and sample['mode']==MODES[ordinal]
            and sample['requestID']==job['requestIDs'][ordinal] and hashed(sample['requestSHA256'])
            and sample['ordinaryRequestScopeSHA256']==text_hash([value['ordinaryInputScopeSHA256'],
                'iteration='+str(ordinal),sample['requestSHA256']]),'Width request/variant scope')
        actual=sample['actualTargetArgmax']
        require(len(actual)==16 and all(integer(x) and x<262144 for x in actual)
            and sample['forcedInputSequence']==reference[:15] and sample['expectedGreedyIDs']==reference
            and sample['allArgmaxMatchReference'] is (actual==reference)
            and sample['referenceGeneratedInThisSession'] is (ordinal==0)
            and sample['teacherForcedInputs'] is (ordinal!=0),'Width actual forced packet')
        require(sample['checkpointFrontier']==132 and sample['checkpointState']['frontier']==132
            and len(sample['checkpointState']['entries'])==90,'Width checkpoint state count')
        rows=sample['rows'];require(len(rows)==6,'Width six complete rows')
        prefix=f'request-{ordinal}-width-{MODES[ordinal].lower()}'
        for row,out_ordinal in zip(rows,ROW_ORDINALS):
            require(set(row)=={'outputOrdinal','logicalInputFrontier','evaluatedWindowBase','evaluatedWindowWidth',
                'retainedWindowInputs','argmax','file'},'Width row fields')
            if out_ordinal==0:base,width,keep=64,64,64
            elif out_ordinal in (1,15) or ordinal in (0,1):base,width,keep=127+out_ordinal,1,1
            elif ordinal==2:base,width,keep=129,3,3
            else:base,width,keep=127+out_ordinal,3,1
            require([row[k] for k in ('outputOrdinal','logicalInputFrontier','evaluatedWindowBase','evaluatedWindowWidth','retainedWindowInputs')]
                ==[out_ordinal,128+out_ordinal,base,width,keep] and row['argmax']==actual[out_ordinal],
                'Width logical row versus actual evaluated/retained window')
            file_record(row['file']);require(row['file']['name']==f'{prefix}-row-{out_ordinal}.json','Width row filename')
            if out_ordinal!=15:expected_files.append(row['file'])
        for layer in range(30):
            for component,entry in zip(('kv.keys','kv.position_offsets','kv.values'),sample['checkpointState']['entries'][layer*3:layer*3+3]):
                require(entry['globalLayerIndex']==entry['localLayerIndex']==layer and entry['component']==component,
                    'Width all30 complete layer identities')
                file_record(entry['file']);require(entry['file']['name']==f'{prefix}-state-{layer}-{component}.bin','Width state filename')
                expected_files.append(entry['file'])
        expected_files.append(rows[-1]['file'])
    first=value['samples'][0]
    require(value['referenceRequestID']==first['requestID'] and value['referenceRequestSHA256']==first['requestSHA256']
        and first['actualTargetArgmax']==reference,'Width reference is actual ordinary first request')
    require(value['allActualTargetArgmaxMatchReference'] is all(s['allArgmaxMatchReference'] for s in value['samples']),
        'Width aggregate actual argmax flag')
    scope=text_hash(['gemma4_target_width_qualification_v1',value['ordinaryInputScopeSHA256'],
        'reference='+value['referenceRequestSHA256'],'tokens='+value['referenceSelectedTokenIDsSHA256'],
        'checkpoint=132','assistant=false','performance=false']+list(MODES)+[POLICY])
    require(value['scopeSHA256']==scope,'Width diagnostic scope')
    require(value['files']==expected_files and len(value['files'])==384
        and len({x['name'] for x in value['files']})==384,'Width exact ordered sidecars')
    load=value['sourceLoad'];resources=value['resources'];extra=value['targetResources']
    require(load['target']=='full-reference' and load['selectedTensorCount']==1339 and load['sourceTensorCount']==1697
        and load['planSHA256']==value['planSHA256'],'Width full registered source')
    require(resources['completedTensorCount']==resources['selectedTensorCount']==1339
        and resources['minimumActualFreeBytes']>=6*1024**3 and resources['operationalResourceChecksApplied'] is True
        and resources['actualAllocatorBoundsUsed'] is True and resources['newServingActivationFloorEstablished'] is False,
        'Width original target admission')
    require(extra['policy']=='gemma4_mtp_remote_target_resources_v1' and extra['assistantLoadedOnTarget'] is False
        and extra['servingFloorChanged'] is False and extra['wholeProcessPeakBoundEstablished'] is False
        and extra['physicalRetirementEstablished'] is False and extra['requestSHA256']==first['requestSHA256']
        and hashed(extra['budgetSHA256']) and integer(extra['observations'],1)
        and extra['minimumActualFreeBytes']>=6*1024**3 and integer(extra['maximumObservedActiveBytes'])
        and extra['hostBytes']==16*1024**2+32768,'Width additive target resource scope')
    require(len(extra['baseTerms'])==34 and extra['baseNativeBytes']==validate_terms(extra['baseTerms'])
        and extra['verificationNativeBytes']==validate_terms(extra['verificationTerms'])
        and extra['verificationTerms'] and extra['verificationNativeBytes']>0,'Width actual extra resource sums')
    head=[x for x in extra['baseTerms'] if x['name'].startswith('serialTargetHead:')]
    require([x['name'] for x in head]==['serialTargetHead:row'+str(i) for i in range(4)]
        and all(x['logicalBytes']==1024**2 and x['allocationBound']>=1024**2 for x in head),
        'Four individually allocation-rounded F32 head rows are required')
    require(extra['budgetSHA256']==text_hash(['gemma4_mtp_remote_target_resources_v1',extra['requestSHA256'],
        'maximumFrontier=143','depth=2','buffer=5','host='+str(extra['hostBytes'])]
        +[x['name']+':'+str(x['logicalBytes'])+':'+str(x['allocationBound']) for x in extra['baseTerms']]),
        'Dense head and original terms must bind the exact native resource fingerprint')
    return value
