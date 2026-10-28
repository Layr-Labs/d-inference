"""Invented CPU records/processes only; never selected by the real launcher."""
import copy
import json
import os
from pathlib import Path
import sys

from physical_common import canonical,make_jobs,read_plan,write_json
from rank_validation import RankValidator,jaccl,digest
import cut12_pair_final as final
import cut12_pair_storage as storage
import cut12_pair_wire as pair_wire
import cut12_rank_trace as trace
import cut12_rank_wire as wire
from solo_reference import REFERENCE_PINS
from worker_contract import SCHEMA,WorkerSpec
from selected_read_accounting import ALIGNMENT, SCRATCH, FIELD, CONSTANTS, ceiling

GIB=1024**3


def resources(start):
    page=16384;free=12*GIB//page;inactive=GIB//page;speculative=1024
    return dict(os=dict(startedNanoseconds=start,completedNanoseconds=start+10,timestampUTC='2026-09-15T00:00:00Z',
        physicalMemoryBytes=48*GIB,pageSizeBytes=page,kernelFreePages=free+speculative,freePages=free,
        inactivePages=inactive,speculativePages=speculative,actualFreeBytes=free*page,
        estimatedReclaimableBytes=(free+inactive+speculative)*page,pressureLevel=1,swapUsedBytes=0),
        powerSource='ac',lowPowerModeEnabled=False,thermalState=0,sampledOutsideRequestClock=True,
        wholeProcessMemorySafetyEstablished=False)


def ready(v,rank,pid):
    job=v.jobs[rank];e=v.reference.evidence;descriptor=v.cohort();fp=digest(b'qwen-long-prefill-resident-cohort-v1|'+canonical(descriptor))
    bundle=job['peer']['deployment']+'/bundle'
    load=copy.deepcopy(v.loads[rank]);sizes=[item['byteCount'] for item in load['activeTensors']]
    padded=[ceiling(size,ALIGNMENT)*ALIGNMENT for size in sizes]
    load[FIELD]=dict(CONSTANTS,selectedBytes=sum(sizes),requestedReadBytes=sum(padded),
        returnedReadBytes=sum(padded),paddingReadBytes=sum(padded)-sum(sizes),
        preadCalls=sum(ceiling(size,SCRATCH) for size in padded),interruptedCalls=0,shortEOFReads=0,
        largestScratchRequestBytes=SCRATCH,largestScratchAllocationBytes=SCRATCH)
    return dict(execution=dict(kind='qwen_long_prefill_resident_rank_ready',schemaVersion=1,rank=rank,worldSize=2,transport='jaccl',
        jacclConfiguration=jaccl(job),cohortAgreement=descriptor,
        cohortReadiness=dict(cohortAgreementFingerprint=fp,readinessMaterialSHA256=digest(('qwen-long-prefill-resident-cohort-readiness-v1|'+fp).encode())),
        sourceLoad=load,arithmeticEnvironment=e['arithmeticEnvironment'],
        arithmeticEnvironmentSHA256=e['arithmeticEnvironmentSHA256'],resourceAdmission=e['resourceAdmission'],requestCount=4,warmupCount=1,
        verifiedModelLoaded=True,freshRequestStateCreated=False,correctnessOnly=True,throughputMeasurementValid=False,
        physicalTransferQualified=False,independentNumericalComparisonPerformed=False),
        initialResources=resources(100),loadedResources=resources(200),runtime=dict(executableName='cluster-inference',
            mainBundleName='bundle',executablePath=bundle+'/cluster-inference',mainBundlePath=bundle,mainBundleResourcePath=bundle,
            processID=pid,operatingSystemVersion='Fabricated OS',deviceArchitecture='fabricated-cpu-only',deviceMemoryBytes=48*GIB,
            maximumBufferBytes=32*GIB,recommendedWorkingSetBytes=32*GIB,binaryOrBundleHashVerifiedByNative=False,
            providerEligibilityEstablished=False,recommendedWorkingSetUsedForAdmission=False))


def result(v,rank,command):
    a=v.a;ref=v.reference;ordinal=command['sequence']-1;recorded,simple,history=wire.request(a,ref.prompt,command['epoch'])
    summary=dict(profileFingerprint=a.PROFILE and ref.evidence['profileFingerprint'],requestFingerprint=simple,recordedRequestFingerprint=history,
        promptFileSHA256=REFERENCE_PINS['prompt.json'],promptTokenIDsSHA256=ref.evidence['promptTokenIDsSHA256'],
        arithmeticEnvironmentSHA256=ref.evidence['arithmeticEnvironmentSHA256'],argmaxTokenID=ref.token,finalLogits=ref.logits)
    ids=[storage.identity(a,r,v.loads[r],summary) for r in (0,1)]
    agreement=wire.agreement(a,command['epoch'],'serial_v1',recorded,summary,v.loads)
    fp=wire.fingerprint(a,'qwen-profiled-prefill-start-agreement-v1',canonical(agreement))
    frames=[]
    for i,step in enumerate(recorded['steps']):
        header=wire.boundary(a,step,summary,v.loads,digest(('invented-payload-%d'%i).encode()))
        envelope=dict(version=4,flow=wire.FLOW,kind='boundary',agreementFingerprint=fp,boundary=header)
        raw=canonical(envelope)
        frames.append(dict(commit=pair_wire.commit(ids[rank],history,step['frame'],rank==1),exactEnvelopeJSON=raw.decode(),
            envelopeFingerprint=wire.fingerprint(a,'qwen-profiled-prefill-boundary-envelope-v1',raw),envelopeWireBytesSHA256=digest(raw)))
    token=wire.token_content(a,dict(value=agreement,fingerprint=fp),summary,frames[-1]);raw=canonical(token)
    x=dict(kind='qwen_long_prefill_rank_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=True,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        profile=a.PROFILE,profileFingerprint=summary['profileFingerprint'],agreementFingerprint=fp,identity=ids[rank],
        readiness=wire.readiness(a,fp),frames=frames,actions=trace.expected_actions(rank,'serial_v1'),selectedTokenID=ref.token,
        exactTokenPacketJSON=raw.decode(),tokenPacketFingerprint=wire.fingerprint(a,'qwen-profiled-prefill-first-token-packet-v1',raw),
        tokenPacketWireBytesSHA256=digest(raw),finalDigest=final.expected_final(a,rank,ref.evidence,summary,v.loads[rank],ids[rank],fp),
        completedFrames=16,committedTokens=8192,preparedAheadFrames=0,releasedOriginalBoundaryHandles=16,
        postStopReleaseCompleted=True,allRequestStateRetired=True,originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
    start=1000+ordinal*1000
    if rank==0:x['timing']=dict(trace.timing_flags(),startUptimeNanoseconds=start,stopUptimeNanoseconds=start+100,
        elapsedNanoseconds=100,promptTokensPerFirstTokenSecond=8192e9/100,postStopThroughRequestCloseNanoseconds=20)
    else:x['localSelection']=pair_wire.token(ids[rank],summary,recorded['steps'][-1]['frame'])
    wrapper=dict(ordinal=ordinal,excludedWarmup=ordinal==0,epoch=command['epoch'],request=recorded,
        promptFileSHA256=REFERENCE_PINS['prompt.json'],agreement=agreement,execution=x,weightsRemainResident=True)
    return dict(command=copy.deepcopy(command),step=dict(ordinal=ordinal,excludedWarmup=ordinal==0,
        requestID=recorded['request']['requestID'],recordedRequestFingerprint=history,promptFileSHA256=REFERENCE_PINS['prompt.json']),
        execution=wrapper,resourcesBeforeRequest=resources(start-20),resourcesAfterRequest=resources(start+130))


def released():
    phases=['before_resident_stage_load','resident_stage_loaded_no_request_state']+[
        'resident_request_%d_retired_weights_resident'%i for i in range(4)]+['resident_stage_released_cache_cleared']
    return dict(completedRequestCount=4,modelLoadCount=1,modelReleased=True,allRequestStateRetired=True,correctnessOnly=True,
        throughputMeasurementValid=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        resourcesAfterRelease=resources(5000),memory=[dict(phase=p,activeMLXBytes=1 if i in (0,6) else 3*GIB,
        cachedMLXBytes=0,peakMLXBytesSinceProcessStart=4*GIB) for i,p in enumerate(phases)])


def stopped():return dict(completedRequestCount=4,modelReleased=True,allRequestStateRetired=True,explicitShutdownAccepted=True,
    correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False)


def emit(kind,row,job):
    sys.stdout.write(json.dumps(dict(schema=SCHEMA,type=kind,cohort_id=job['opened']['cohort_id'],role='rank',rank=job['rank'],record=row),separators=(',',':'))+'\n');sys.stdout.flush()


def native(jobfile,rank,scenario):
    jobs=json.loads(Path(jobfile).read_bytes());v=RankValidator(jobs,lambda r:{},lambda r,e:'0'*64);job=jobs[rank]
    opened=json.loads(sys.stdin.buffer.readline())
    if scenario in ('retry','retry_partial','retry_unknown'):
        diagnostic=b'[jaccl] Connection attempt 0 waiting 1000 ms\n'
        if scenario=='retry_partial':diagnostic=diagnostic[:-1]
        if scenario=='retry_unknown':diagnostic+=b'warning\n'
        os.write(2,diagnostic[:7]);os.write(2,diagnostic[7:])
    initial=ready(v,rank,os.getpid())
    v.loads[rank]=copy.deepcopy(initial['execution']['sourceLoad'])
    emit('ready',initial,job)
    for i in range(4):
        command=json.loads(sys.stdin.buffer.readline())
        if scenario=='retry_late' and i==0:os.write(2,b'[jaccl] Connection attempt 0 waiting 1000 ms\n')
        if scenario=='hang' and i==0:
            import time;time.sleep(10)
        row=result(v,rank,command)
        if scenario=='bad_token' and rank==1 and i==0:row['execution']['execution']['selectedTokenID']=1
        emit('result',row,job)
    emit('released',released(),job);json.loads(sys.stdin.buffer.readline());emit('stopped',stopped(),job)


if __name__=='__main__':native(sys.argv[1],int(sys.argv[2]),sys.argv[3])
