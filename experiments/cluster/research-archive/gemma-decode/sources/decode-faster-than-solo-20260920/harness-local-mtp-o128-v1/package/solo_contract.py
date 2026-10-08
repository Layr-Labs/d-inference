"""Closed ordinary full-role result. Model equality is checked after retirement."""
import math
import re
from binding_common import require
from workload_contract import counts

FLAGS = dict(modelReleased=True, nativeExecuted=True, runtimeServingEnabled=False,
    encryptedRDMAEstablished=False, numericalComparisonPerformed=False,
    physicalProcessOrLeaseRetirementEstablished=False, collectiveCreated=False, collectiveReleased=False)
FIELDS = set(FLAGS) | {'schema','job','scopeSHA256','planSHA256','sourceLoad',
    'loadStartedNanoseconds','loadCompletedNanoseconds','probeCompletedNanoseconds',
    'samples','resources','files','measuredRequests','warmupRequests',
    'nativeCacheBytesAfterRelease','guardMetrics','guardObservationPolicy'}
SAMPLE_FLAGS = dict(requestStateRetired=True, evidenceOutsideTimedPath=True,
    timingsAreSameProcess=True, clockAcrossHostsCompared=False,
    durationIncludesResourceChecksAndSerialTransport=True, mtpEnabled=False, numericalComparisonPerformed=False)
SAMPLE_FIELDS = set(SAMPLE_FLAGS) | {'ordinal','warmup','requestID','requestSHA256','binding',
    'selectedTokenIDs','selectedTokenIDsSHA256','startedNanoseconds','firstLogitsNanoseconds',
    'tokenAgreementNanoseconds','completedNanoseconds','prefillNanoseconds','decodeNanoseconds',
    'prefillTokensPerSecond','decodeTokensPerSecond','frames','committedTokens','guardMetrics'}


def integer(value, minimum=0):
    return type(value) is int and minimum <= value < 2**64


def validate_result(value, job):
    c=counts(job)
    require(type(value) is dict and set(value)==FIELDS, 'Solo result fields differ')
    require(value['schema']=='gemma4_resident_benchmark_result_v1' and value['job']==job
        and job['mode']=='full' and job['prefillPolicy']=='serial', 'Solo result input/operation differs')
    require(type(job['captureEvidence']) is bool, 'Solo capture policy')
    for key,wanted in FLAGS.items():require(value[key] is wanted, 'Wrong solo flag: '+key)
    require(value['nativeCacheBytesAfterRelease']==0 and value['measuredRequests']==3
        and value['warmupRequests']==1 and len(value['samples'])==4, 'Solo cohort/cache count')
    for key in ('scopeSHA256','planSHA256'):
        require(type(value[key]) is str and re.fullmatch('[0-9a-f]{64}',value[key]) is not None, 'Solo identity: '+key)
    require(value['guardObservationPolicy']=='gemma4_invocation_fresh_observation_v1'
        and value['guardMetrics']['schema']=='gemma4_guard_wall_counters_v1'
        and value['guardMetrics']['overflow'] is False, 'Solo resource observation policy')
    times=[value[k] for k in ('loadStartedNanoseconds','loadCompletedNanoseconds','probeCompletedNanoseconds')]
    require(all(integer(x,1) for x in times) and times==sorted(times), 'Solo load/probe chronology')
    rows=[]
    for ordinal,sample in enumerate(value['samples']):
        capture={'finalRow','finalState'} if job['captureEvidence'] else set()
        require(type(sample) is dict and set(sample)==SAMPLE_FIELDS|capture, 'Solo sample fields differ')
        for key,wanted in SAMPLE_FLAGS.items():require(sample[key] is wanted, 'Wrong solo sample flag: '+key)
        require(sample['ordinal']==ordinal and sample['warmup'] is (ordinal==0)
            and sample['requestID']==job['requestIDs'][ordinal], 'Solo request identity/order')
        tokens=sample['selectedTokenIDs']
        require(len(tokens)==c['output'] and all(type(x) is int and 0<=x<262144 for x in tokens)
            and sample['committedTokens']==c['frontier'], 'Solo tokens/frontier')
        rows.append(tokens)
        for key in ('requestSHA256','selectedTokenIDsSHA256'):
            require(type(sample[key]) is str and re.fullmatch('[0-9a-f]{64}',sample[key]) is not None, 'Solo request digest')
        start,first,end=sample['startedNanoseconds'],sample['firstLogitsNanoseconds'],sample['completedNanoseconds']
        agreements=sample['tokenAgreementNanoseconds']
        require(all(integer(x,1) for x in [start,first,end,*agreements]) and len(agreements)==c['output']
            and start<first<=agreements[0]<agreements[-1]<=end and agreements==sorted(agreements), 'Solo actual clock chronology')
        require(sample['prefillNanoseconds']==agreements[0]-start
            and sample['decodeNanoseconds']==agreements[-1]-agreements[0], 'Solo timing boundaries')
        for phase,count in [('prefill',job['promptCount']),('decode',c['decode'])]:
            ns=sample[phase+'Nanoseconds'];tps=sample[phase+'TokensPerSecond']
            require(integer(ns,1) and type(tps) in (int,float) and math.isfinite(tps) and tps>0
                and math.isclose(tps,count*1e9/ns,rel_tol=1e-12), 'Solo same-clock throughput arithmetic')
        require(len(sample['frames'])==c['frames'], 'Solo forward frame count')
        if job['captureEvidence']:
            require(sample['finalRow']['bytes']>0 and sample['finalState']['frontier']==c['frontier']
                and len(sample['finalState']['entries'])==90, 'Solo requested row/whole-state evidence')
    require(all(x==rows[0] for x in rows), 'Solo fresh-state reproducibility')
    require(job['captureEvidence'] or value['files']==[], 'Unrequested solo sidecars')
    resources=value['resources']
    require(resources['completedTensorCount']==resources['selectedTensorCount']==1339
        and resources['minimumActualFreeBytes']>=6*1024**3 and resources['operationalResourceChecksApplied'] is True
        and resources['actualAllocatorBoundsUsed'] is True and resources['newServingActivationFloorEstablished'] is False,
        'Solo original resource admission')
    return value
