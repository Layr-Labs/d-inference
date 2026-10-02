"""Exact numerical-report checks; physical retirement is validated separately."""
import hashlib
import re
from binding_common import canonical, require, same
from gemma_inputs import validate_job
ARTIFACT='2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
CONFIG='29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa'
COUNTS=[1,7,8,9,33]
def sha(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None
def digest(value):return hashlib.sha256(canonical(value)).hexdigest()
def maps(experts):
    cut=6 if experts==16 else 48
    return [[list(range(cut)),list(range(cut,experts))],[[x for x in range(experts) if x%3==0],[x for x in range(experts) if x%3!=0]]]
def difference(value,count):
    require(type(value) is dict and value['exactBytes'] is True and type(value['values']) is int and value['values']==count,'Exact expert difference geometry')
    require(sha(value['referenceSHA256']) and value['referenceSHA256']==value['candidateSHA256'],'Exact expert bytes/digest')
    require(value['maximumAbsoluteError']==0 and value['relativeRMSError']==0,'Numerical error exceeds exact acceptance')
def comparison(value,rows,hidden,ownership):
    top=value['topK'];ids=value['selectedGlobalIDs'];counts=value['assignmentCounts'];experts=sum(map(len,ownership))
    require(value['tokenCount']==rows and type(top) is int and 1<=top<=8 and len(ids)==rows,'Expert case geometry')
    require(all(len(x)==top and len(set(x))==top and all(type(i) is int and 0<=i<experts for i in x) for x in ids),'Expert selected IDs')
    expected=[sum(i in bank for row in ids for i in row) for bank in ownership]
    same(counts,expected,'Expert original-slot assignment conservation')
    require(sha(value['routingWeightsSHA256']),'Expert route weight digest')
    difference(value['expertOutputs'],rows*top*hidden);difference(value['weighted'],rows*hidden)
    if value.get('postNorm') is not None:difference(value['postNorm'],rows*hidden)
def scope(job):
    return hashlib.sha256('\n'.join([job['schema'],job['membershipEpoch'],job['requestID'],job['buildIdentitySHA256'],job['ownership'],
        'layer='+str(job['layer']),'tokens='+','.join(map(str,job['tokenCounts'])),'timeout='+str(job['timeoutSeconds']),
        ARTIFACT,CONFIG,'bf16-w4-g64-original-top8-slots-v1']).encode()).hexdigest()
def validate_result(value,job):
    validate_job(job)
    require(value.get('passed') is True and value.get('actualQuantizedTensorsExecuted') is True
            and value.get('expertBanksReleased') is True and value.get('nativeCacheBytesAfterRelease')==0,'Expert result/retirement')
    require(value.get('runtimeServingEnabled') is False and value.get('throughputMeasurementValid') is False
            and value.get('physicalProcessOrLeaseRetirementEstablished') is False
            and value.get('fullDecoderExecuted') is False and value.get('deviceOnlyDynamicRoutingQualified') is False
            and value.get('wholeProcessMemoryBoundEstablished') is False,'Expert scope differs')
    if job['kind']!='rdma':return primitive(value,job)
    native=job['nativeJob'];rank=native['rank'];ownership=maps(128)[0 if native['ownership']=='contiguous48_80' else 1]
    same(value['job'],native,'RDMA exact original job')
    require(value['schema']=='gemma4_expert_rdma_result_v1' and value['scopeSHA256']==scope(native)
            and value['artifactAggregateSHA256']==ARTIFACT and value['globalExpertIDsByRank']==ownership,'RDMA job/source/ownership')
    require(value['distributedExecution'] is True and value['collectiveReleased'] is True and value['nativeExecuted'] is True
            and value['checkpointUnchanged'] is True and value['encryptedRDMA'] is False
            and value['authoritativeCPUFixtureRouteReadback'] is True,'RDMA scope/retirement')
    require(value['loadedLocalExpertBytes']==len(ownership[rank])*3345408
            and value['loadedReferenceExpertBytes']==(428212224 if rank==0 else 0),'Real selected expert bytes')
    require(value['minimumActualFreeBytes']>=6*1024**3 and value['resourceObservations']>0,'RDMA actual resource observations')
    for key in ['sentControlBytes','receivedControlBytes']:
        require(type(value[key]) is int and 0<value[key]<=128*(32768+4),'RDMA bounded control traffic')
    for key in ['reservedNativeBytes','hostReserveBytes','maximumObservedActiveBytes']:
        require(type(value[key]) is int and value[key]>0,'RDMA observed resource geometry')
    require(len(value['cases'])==len(native['tokenCounts']),'RDMA case count')
    for index,(case,rows) in enumerate(zip(value['cases'],native['tokenCounts'])):
        require(case['ordinal']==index and case['tokenCount']==rows and case['acceptedByReferenceRank'] is True
                and type(case['localAssignmentCount']) is int and 0<=case['localAssignmentCount']<=rows*8,'RDMA exact case')
        for name in ['routeSHA256','inputSHA256','weightsSHA256','transferredOutputSHA256','referenceResultSHA256']:require(sha(case[name]),'RDMA digest')
        if rank==0:
            c=case['comparison'];comparison(c,rows,2816,ownership)
            require(c['label']==f"checkpoint-layer-{job['layer']}/two-rank/{native['ownership']}" and c['inputDType']=='bfloat16'
                    and c['topK']==8 and c['postNorm'] is not None and c['routingWeightsSHA256']==case['weightsSHA256']
                    and c['assignmentCounts'][0]==case['localAssignmentCount']
                    and digest(c['selectedGlobalIDs'])==case['routeSHA256'] and digest(c)==case['referenceResultSHA256'],'RDMA full original-slot reference')
        else:require(case.get('comparison') is None,'Follower cannot substitute a local comparison')
    tensor_rows=sum(native['tokenCounts']) if rank==0 else sum(c['localAssignmentCount'] for c in value['cases'])
    require(value['sentTensorBytes']==tensor_rows*2816*2,'Exact sent tensor traffic')
    if rank==1:require(value['receivedTensorBytes']==sum(native['tokenCounts'])*2816*2,'Exact follower received tensor traffic')
    else:require(value['receivedTensorBytes']==sum(c['comparison']['assignmentCounts'][1] for c in value['cases'])*2816*2,'Exact owner received tensor traffic')
def primitive(value,job):
    small=job['kind']=='synthetic-small';checkpoint=job['kind']=='checkpoint'
    count=60 if small else (10 if checkpoint else 30);hidden=128 if small else 2816;experts=16 if small else 128
    dtypes=['float32','bfloat16'] if small else ['bfloat16'];layouts=maps(experts)
    require(value['schema']=='gemma_expert_axis_native_check_v1' and value['mode']=='--'+job['kind']
            and value['caseCount']==count and len(value['cases'])==count and value['hiddenSize']==hidden
            and value['expertIntermediateSize']==704 and value['globalExpertCount']==experts
            and value['distributedExecution'] is False,'Primitive result scope')
    require(value['invalidNativeContractsRefusedPerOwnership']==5 and value['expertOwnershipMaps']==layouts*len(dtypes)
            and len(value['resources'])==len(dtypes)*2,'Primitive complete ownership/refusal/resource coverage')
    if checkpoint:require(value['checkpointPayloadVerified'] is True and value['checkpointUnchanged'] is True
        and value['artifactAggregateSHA256']==ARTIFACT and value['globalLayerIndex']==job['layer'],'Real checkpoint identity')
    else:require(value['checkpointPayloadVerified'] is False and value['checkpointUnchanged'] is False
        and value['artifactAggregateSHA256'] is None and value['globalLayerIndex'] is None,'Synthetic source scope')
    remaining=list(value['cases'])
    for dtype in dtypes:
        for index,ownership in enumerate(layouts):
            for rows in COUNTS:
                for pattern in (['actual-router-replay'] if checkpoint else ['balanced','all-rank0','all-rank1']):
                    case=remaining.pop(0);comparison(case,rows,hidden,ownership)
                    prefix=f"checkpoint-layer-{job['layer']}" if checkpoint else 'synthetic'
                    require(case['label']==f'{prefix}/{dtype}/ownership-{index}/{pattern}' and case['inputDType']==dtype
                            and (case.get('postNorm') is not None)==checkpoint,'Exact primitive case order/policy')
                    if checkpoint:require(case['topK']==8,'Actual checkpoint top8')
                    else:
                        rank=None if pattern=='balanced' else (0 if pattern=='all-rank0' else 1)
                        top=8 if rank is None else min(8,len(ownership[rank]))
                        ids=[[(row*7+slot*3)%experts if rank is None else ownership[rank][(row*3+slot)%len(ownership[rank])]
                              for slot in range(top)] for row in range(rows)]
                        same(case['selectedGlobalIDs'],ids,'Exact synthetic assignment packet');require(case['topK']==top,'Synthetic topK')
    require(not remaining,'Extra primitive cases')
    for row in value['resources']:
        require(row['minimumActualFreeBytes']>=6*1024**3 and row['observations']>0,'Primitive resource observations')
def validate_pair(left,right):
    require(left['scopeSHA256']==right['scopeSHA256'],'Peer original scope differs')
    for sent,received in [('sentTensorBytes','receivedTensorBytes'),('sentControlBytes','receivedControlBytes')]:
        require(left[sent]==right[received] and right[sent]==left[received],'Peer traffic accounting differs')
    for a,b in zip(left['cases'],right['cases']):
        for name in ['ordinal','tokenCount','routeSHA256','inputSHA256','weightsSHA256','transferredOutputSHA256','referenceResultSHA256','acceptedByReferenceRank']:
            same(a[name],b[name],'Peer case '+name)
        require(a['comparison']['assignmentCounts']==[a['localAssignmentCount'],b['localAssignmentCount']], 'Both original assignment counts')
