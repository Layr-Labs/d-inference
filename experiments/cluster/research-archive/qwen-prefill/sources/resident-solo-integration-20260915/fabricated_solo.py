"""Fabricated CPU-only native-shaped records for the integration's tests."""
import copy
import json
import os
from pathlib import Path
import sys

from solo_reference import Reference, REFERENCE_PINS
from stage_checks.long_identity import recorded_request, request_identity
from worker_contract import SCHEMA

GIB = 1024**3


def resources(start):
    page = 16384
    free, inactive, speculative = 12*GIB//page, 2*GIB//page, 1024
    return dict(os=dict(startedNanoseconds=start, completedNanoseconds=start+10,
        timestampUTC='2026-09-15T00:00:00Z', physicalMemoryBytes=48*GIB, pageSizeBytes=page,
        kernelFreePages=free+speculative, freePages=free, inactivePages=inactive,
        speculativePages=speculative, actualFreeBytes=free*page,
        estimatedReclaimableBytes=(free+inactive+speculative)*page, pressureLevel=1, swapUsedBytes=0),
        powerSource='ac', lowPowerModeEnabled=False, thermalState=0,
        sampledOutsideRequestClock=True, wholeProcessMemorySafetyEstablished=False)


def ready(ref, pid, bundle):
    e = ref.evidence
    return dict(execution=dict(kind='qwen_long_prefill_resident_solo_ready',schemaVersion=1,
        source=copy.deepcopy(ref.execution['source']),sourceLoad=copy.deepcopy(ref.execution['sourceLoad']),
        arithmeticEnvironment=copy.deepcopy(e['arithmeticEnvironment']),
        arithmeticEnvironmentSHA256=e['arithmeticEnvironmentSHA256'],resourceAdmission=copy.deepcopy(e['resourceAdmission']),
        requestCount=4,warmupCount=1,verifiedModelLoaded=True,freshRequestStateCreated=False,
        correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,
        independentNumericalComparisonPerformed=False), initialResources=resources(100),loadedResources=resources(200),
        runtime=dict(executableName='cluster-inference',mainBundleName=Path(bundle).name,
            executablePath=str(Path(bundle)/'cluster-inference'),mainBundlePath=str(bundle),mainBundleResourcePath=str(bundle),
            processID=pid,operatingSystemVersion='Fabricated OS',deviceArchitecture='fabricated-cpu-test',
            deviceMemoryBytes=48*GIB,maximumBufferBytes=32*GIB,recommendedWorkingSetBytes=32*GIB,
            binaryOrBundleHashVerifiedByNative=False,providerEligibilityEstablished=False,
            recommendedWorkingSetUsedForAdmission=False))


def result(ref, command):
    ordinal = command['sequence']-1
    identifier, simple, history = request_identity(command['epoch'], ref.prompt)
    start = 1000+ordinal*1000
    elapsed = 100
    execution = copy.deepcopy(ref.execution)
    for key in ('candidateNumericalComparisonPerformed','intermediateNumericalStatesExported'):
        execution.pop(key)
    for key in ('cpuCrosscheckPolicy','maximumLogit','maximumTieCount','nativeSelectionMatchesCapturedFullRow'):
        execution['selection'].pop(key)
    execution['selection'].update(requestFingerprint=simple,recordedRequestFingerprint=history)
    execution['finalLogits'].pop('values')
    execution['request']=recorded_request(command['epoch'],ref.prompt)
    # Synthesized Swift UUID strings are uppercase, while identity recipes lower them.
    execution['request']['request']['requestID']=identifier.upper()
    execution.update(kind='qwen_long_prefill_solo_request',schemaVersion=1,
        correctnessOnly=True,throughputMeasurementValid=False,interprocessTransportUsed=False,
        physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        fullVocabularyValuesExported=False,nativeLogitBytesCompared=False,
        timing=dict(startUptimeNanoseconds=start,stopUptimeNanoseconds=start+elapsed,elapsedNanoseconds=elapsed,
            promptTokensPerFirstTokenSecond=8192e9/elapsed,postStopThroughRequestCloseNanoseconds=20,
            includesFreshRequestState=True,includesFiniteArgmaxAndScalarReadback=True,
            includesBoundedCommitMetadata=True,includesTransport=False,
            excludesLoadReadinessFinalCaptureAndRetirement=True))
    return dict(command=copy.deepcopy(command), step=dict(ordinal=ordinal,excludedWarmup=ordinal==0,
        requestID=identifier.upper(),recordedRequestFingerprint=history,promptFileSHA256=REFERENCE_PINS['prompt.json']),
        execution=execution,resourcesBeforeRequest=resources(start-20),resourcesAfterRequest=resources(start+130))


def released():
    phases=['before_resident_full_model_load','resident_full_model_loaded_no_request_state']+[
        'resident_solo_request_%d_retired_weights_resident'%i for i in range(4)]+['resident_full_model_released_cache_cleared']
    return dict(completedRequestCount=4,modelLoadCount=1,modelReleased=True,allRequestStateRetired=True,
        correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,
        independentNumericalComparisonPerformed=False,resourcesAfterRelease=resources(5000),
        memory=[dict(phase=phase,activeMLXBytes=1 if i in (0,6) else 5*GIB,
            cachedMLXBytes=0,peakMLXBytesSinceProcessStart=6*GIB) for i,phase in enumerate(phases)])


def stopped():
    return dict(completedRequestCount=4,modelReleased=True,allRequestStateRetired=True,explicitShutdownAccepted=True,
        correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,
        independentNumericalComparisonPerformed=False)


def envelope(kind, record, cohort):
    return dict(schema=SCHEMA,type=kind,cohort_id=cohort,role='solo',rank=None,record=record)


def main():
    scenario=sys.argv[1]; ref=Reference()
    opened=json.loads(sys.stdin.buffer.readline()); cohort=opened['cohort_id']
    def emit(kind, record):
        sys.stdout.write(json.dumps(envelope(kind,record,cohort),separators=(',',':'))+'\n');sys.stdout.flush()
    value=ready(ref,os.getpid(),Path(sys.executable).parent)
    if scenario=='bad_pid':value['runtime']['processID']+=1
    emit('ready',value)
    for index in range(4):
        command=json.loads(sys.stdin.buffer.readline()); value=result(ref,command)
        if scenario=='bad_logits' and index==1:value['execution']['finalLogits']['logicalBytesSHA256']='0'*64
        if scenario=='bad_resource' and index==0:value['resourcesAfterRequest']['os']['swapUsedBytes']=1
        emit('result',value)
    value=released()
    if scenario=='bad_release':value['modelLoadCount']=2
    emit('released',value)
    command=json.loads(sys.stdin.buffer.readline())
    if command['type']!='shutdown':raise ValueError('Expected explicit shutdown')
    emit('stopped',stopped())


if __name__=='__main__':main()
