"""Validate a local MTP transcript; this does not compare model numerics."""
import hashlib
import math
import re
from binding_common import require


def positive(value):
    return type(value) in (int,float) and math.isfinite(value) and value>0


def validate_result(value,job,config,config_sha,operation):
    require(value['schema']=='gemma4_local_mtp_cohort_result_v1','Local MTP result schema')
    require(value['configuration']==config and value['benchmarkJob']==job,'Local MTP result inputs')
    require(config['schema']=='gemma4_local_mtp_cohort_job_v1'
        and config['maximumDraftTokens'] in (1,2) and type(config['captureEvidence']) is bool,'Local MTP config')
    require(re.fullmatch('[0-9a-f]{64}',config_sha) is not None,'Config pin missing')
    for key in ('mtpEnabled','nativeExecuted','modelReleased','assistantReleased'):
        require(value[key] is True,'Missing local execution/retirement: '+key)
    for key in ('remoteAssistant','targetBatchNumericsQualified','numericalComparisonPerformed',
        'performanceQualified','runtimeServingEnabled','encryptedRDMAEstablished',
        'physicalProcessOrLeaseRetirementEstablished','collectiveCreated','collectiveReleased'):
        require(value[key] is False,'Unexpected local MTP claim: '+key)
    qualify=operation=='qualify-mtp-conditioning'
    require(value['conditioningQualificationRequested'] is qualify and value['conditioningQualificationPassed'] is qualify,
        'Conditioning mode differs')
    require(value['nativeCacheBytesAfterRelease']==0 and value['guardObservationPolicy']=='gemma4_invocation_fresh_observation_v1'
        and value['guardMetrics']['schema']=='gemma4_guard_wall_counters_v1','Native cache/guard policy differs')
    require(value['measuredRequests']==3 and value['warmupRequests']==1 and len(value['samples'])==4,'Cohort count')
    identities=[];qualification_count=0
    for ordinal,sample in enumerate(value['samples']):
        generation=sample['generation'];tokens=generation['selectedTokenIDs']
        require(sample['requestID']==job['requestIDs'][ordinal].lower() and sample['requestStateRetired'] is True,'Request identity/retirement')
        require(sample['performanceQualified'] is False and sample['modelNumericsQualified'] is False,'Premature numerical/performance claim')
        require(generation['ordinal']==ordinal and generation['warmup'] is (ordinal==0),'Warmup identity')
        require(len(tokens)==16 and all(type(x) is int and 0<=x<262144 for x in tokens),'Generated tokens')
        require(sample['selectedTokenIDsSHA256']==hashlib.sha256(','.join(map(str,tokens)).encode()).hexdigest(),
            'Generated token identity differs')
        identities.append(tokens)
        require(generation['committedTokens']==job['promptCount']+15,'Final committed frontier')
        widths=generation['verificationWidths'];accepted=generation['acceptedPrefixes']
        require(len(widths)==len(accepted)==generation['verifiedWindows']
            and all(type(w) is int and 1<=w<=config['maximumDraftTokens']+1 for w in widths)
            and all(type(a) is int and 0<=a<w for a,w in zip(accepted,widths)),'Verification geometry')
        require(generation['proposalTokens']==sum(w-1 for w in widths)
            and generation['acceptedProposalTokens']==sum(accepted)
            and generation['seedSteps']==widths.count(1)
            and len(widths)+sum(accepted)==15,'Accepted/rejected work accounting')
        for flag in ('mtpEnabled','timingsAreSameProcess','rejectedWorkIncluded'):
            require(generation[flag] is True,'Missing measured generation property')
        require(generation['remoteAssistant'] is False and generation['targetBatchNumericsQualified'] is False,'Generation claim')
        for phase,count in [('prefill',job['promptCount']),('decode',15)]:
            ns=generation[phase+'Nanoseconds'];tps=generation[phase+'TPS']
            require(type(ns) is int and ns>0 and positive(tps)
                and math.isclose(tps,count*1e9/ns,rel_tol=1e-12),'Same-clock throughput arithmetic')
        evidence=sample['evidence']
        require(evidence['capturedBeforeRequestRetirement'] is True and evidence['outsideGenerationTiming'] is True
            and evidence['numericalComparisonPerformed'] is False,'Evidence lifecycle/timing')
        has_capture=evidence.get('finalRow') is not None and evidence.get('finalState') is not None
        require(has_capture is config['captureEvidence'],'Requested capture differs')
        conditioning=evidence.get('conditioning')
        if conditioning is not None:
            qualification_count+=1
            require(qualify and ordinal==0 and conditioning['schema']=='gemma4_local_mtp_conditioning_parity_v1'
                and conditioning['frontier']==job['promptCount']+15 and conditioning['seedToken']==tokens[-1]
                and conditioning['depths']==[1,2] and conditioning['exactTokenColumns']==3
                and conditioning['exactHiddenColumns']==3 and conditioning['exactBatchedTokenColumns']==3
                and conditioning['exactBatchedHiddenColumns']==2 and conditioning['negativeControls']==5
                and conditioning['fullTargetEmbeddingUsed'] is True and conditioning['targetForwardInvoked'] is False
                and conditioning['targetBatchNumericsQualified'] is False and conditioning['remoteExecutionQualified'] is False
                and conditioning['outsideGenerationTiming'] is True,'Actual conditioning parity differs')
    require(all(x==identities[0] for x in identities) and qualification_count==int(qualify),'Fresh cohort reproducibility/parity count')
    require(config['captureEvidence'] or value['files']==[],'Unrequested sidecars')
    assistant=value['assistantLoad'];aux=value['auxiliaryResources'];resources=value['resources']
    require(assistant['artifactSHA256']=='d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34'
        and assistant['tensorCount']==94 and assistant['tensorBytes']==236114440
        and assistant['constructorQuantizedParametersUnmaterialized']==69 and assistant['allActualParametersReplaced'] is True,'Registered assistant load')
    require(aux['placement']=='localTarget' and aux['completedItems']==94 and aux['constructorUnmaterializedPackedCount']==69
        and aux['observationCount']>0 and aux['minimumActualFreeBytes']>=6*1024**3
        and aux['verificationNativeReserveBytes']>0 and aux['servingFloorChanged'] is False
        and aux['reclaimableUsedForAdmission'] is False,'Assistant actual resource admission')
    require(resources['completedTensorCount']==resources['selectedTensorCount']==1339
        and resources['minimumActualFreeBytes']>=6*1024**3 and resources['operationalResourceChecksApplied'] is True
        and resources['actualAllocatorBoundsUsed'] is True and resources['newServingActivationFloorEstablished'] is False,
        'Target actual resource admission')
    return value
