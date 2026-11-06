"""Closed cut12/serial resident checks using unchanged pure wire/final helpers."""
import copy
import hashlib
from pathlib import Path
from types import SimpleNamespace
import uuid

import cut12_pair_final as final
import cut12_pair_storage as storage
import cut12_pair_wire as pair_wire
import cut12_rank_trace as trace
import cut12_rank_wire as wire
from binding_inputs import snapshot
from physical_common import canonical, exact, fields, integer, parse, require, sha as verify_sha
from runtime_binding import validate_runtime_pair
from selected_read_accounting import validated_load
from allocator_policy import validate_allocator_policy
from solo_reference import Reference, REFERENCE_PINS
from solo_resources import native_resources
from stage_checks.long_identity import request_identity, recorded_request
from stage_checks.long_profile import PROFILE,PROFILE_SHA256,ARTIFACT,CONFIGURATION


def digest(raw):return hashlib.sha256(raw).hexdigest()


class PureContext:
    """Minimal scalar API expected by the copied pure functions; no dynamic IO/import."""
    PROFILE=PROFILE;ARTIFACT_SHA=ARTIFACT;CONFIG_SHA=CONFIGURATION
    require=staticmethod(require);exact=staticmethod(exact);integer=staticmethod(integer)
    sha=staticmethod(digest);sha_string=staticmethod(verify_sha);canonical=staticmethod(canonical)
    @staticmethod
    def context():return dict(base=SimpleNamespace(parse_json=parse))
    @staticmethod
    def check_depth(raw):
        value=parse(raw)
        def depth(x):
            if type(x) is dict:return 1+max((depth(v) for v in x.values()),default=0)
            if type(x) is list:return 1+max((depth(v) for v in x),default=0)
            return 0
        require(depth(value)<=16,'Encoded JSON exceeds depth bound')
    @staticmethod
    def request_identity(identifier,prompt):return request_identity(uuid.UUID(identifier).hex,prompt)[1:]
    @staticmethod
    def frames_and_commits(prompt):return recorded_request('0'*31+'1',prompt)['steps'],None
    @staticmethod
    def state_fingerprint(entries):
        lines=['cbv2-owned-state-v1','tokens=8192']+[f"{e['globalLayerIndex']}|{e['component']}|{e['shape']}|{e['dtype']}|{e['byteCount']}|{e['sha256']}" for e in entries]
        return digest('\n'.join(lines).encode())


def jaccl(job):
    matrix=digest(canonical(job['matrix'])+b'\n')
    common=dict(schema='qwen_resident_jaccl_configuration_v1',backend='jaccl',topology='mesh',worldSize='2',
        deviceMatrixSHA256=matrix,coordinator=job['coordinator'])
    return dict(backend='jaccl',topology='mesh',worldSize=2,configuredRank=job['rank'],
        deviceMatrixPath=str(Path(job['peer']['run_dir'])/'matrix.json'),deviceMatrixSHA256=matrix,
        coordinator=job['coordinator'],localDevice=job['matrix'][job['rank']][1-job['rank']],
        configurationFingerprint=digest(canonical(common)),physicalDeviceIdentityVerified=False,physicalTransferQualified=False)


class RankValidator:
    def __init__(self,jobs,owners,capture):
        self.jobs,self.owners,self.capture=jobs,owners,capture
        self.reference=Reference();self.a=PureContext();self.ordinal=0
        here=Path(__file__).parent
        saved=snapshot(here/'qualified-source-controls.json',2*1024**2)
        self.source_snapshot=saved
        control=parse(saved['raw']);audit=snapshot(here/'qualified-source-audit.json',2*1024**2)
        require(audit['sha256']==control['cpuAuditSHA256'] and parse(audit['raw'])['status']=='passed','Prior source qualification differs')
        self.loads=control['loads'];require(len(self.loads)==2,'Two qualified stage source receipts required')
        self.ready=[False,False];self.released=[False,False];self.stopped=[False,False]
        self.pending={};self.times=[0,0];self.runtime=[None,None];self.results=[];self.raw_hashes={}

    def cohort(self):
        job=self.jobs[0];ref=self.reference;e=ref.evidence
        entries=[]
        for index,row in enumerate(job['opened']['requests']):
            identifier,_,history=request_identity(row['epoch'],ref.prompt)
            entries.append(dict(ordinal=index,epoch=row['epoch'],requestID=identifier,
                recordedRequestFingerprint=history,promptFileSHA256=REFERENCE_PINS['prompt.json'],excludedWarmup=index==0))
        return dict(schemaVersion=1,kind='qwen_long_prefill_resident_cohort_agreement',initialEpoch=entries[0]['epoch'],
            sourceConfigurationSHA256=CONFIGURATION,expectedArtifactAggregateSHA256=ARTIFACT,
            planFingerprint=self.loads[0]['planSHA256'],arithmeticEnvironmentSHA256=e['arithmeticEnvironmentSHA256'],
            resourceAdmissionSHA256=digest(canonical(e['resourceAdmission'])),profile=PROFILE,profileFingerprint=PROFILE_SHA256,
            schedulingPolicy='serial_v1',logitsDType='bfloat16',transport='jaccl',executionPath='cbv2-contiguous',
            jacclConfigurationSHA256=jaccl(job)['configurationFingerprint'],requestCount=4,warmupCount=1,
            tracePathsDisabled=True,requests=entries)

    def identity(self,spec,event,command):
        rank=integer(spec.rank,0,1);job=self.jobs[rank];kind=event['type'];row=event['record'];ref=self.reference
        require(spec.role=='rank','Rank-only cohort')
        if kind=='ready':
            require(not self.ready[rank] and self.ordinal==0,'Duplicate ready')
            fields(row,'execution initialResources loadedResources runtime allocatorPolicy','ready')
            actual_load = validated_load(row['execution'].get('sourceLoad'), self.loads[rank])
            validate_allocator_policy(row['allocatorPolicy'], actual_load['loadedTensorBytes'])
            descriptor=self.cohort();fp=digest(b'qwen-long-prefill-resident-cohort-v1|'+canonical(descriptor))
            expected=dict(kind='qwen_long_prefill_resident_rank_ready',schemaVersion=1,rank=rank,worldSize=2,transport='jaccl',
                jacclConfiguration=jaccl(job),cohortAgreement=descriptor,
                cohortReadiness=dict(cohortAgreementFingerprint=fp,readinessMaterialSHA256=digest(('qwen-long-prefill-resident-cohort-readiness-v1|'+fp).encode())),
                sourceLoad=actual_load,arithmeticEnvironment=ref.evidence['arithmeticEnvironment'],
                arithmeticEnvironmentSHA256=ref.evidence['arithmeticEnvironmentSHA256'],resourceAdmission=ref.evidence['resourceAdmission'],
                requestCount=4,warmupCount=1,verifiedModelLoaded=True,freshRequestStateCreated=False,
                correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False)
            exact(row['execution'],expected,'Ready source/cohort/JACCL identity differs')
            self.loads[rank] = actual_load
            owner=self.owners(rank)
            require(owner['rank']==rank and owner['nativeSHA256']==job['native_sha256'],'Remote owner differs')
            self.runtime[rank]=validate_runtime_pair(row['runtime'],row['runtime'],owner['nativePID'],
                [str(Path(job['peer']['deployment'])/'bundle')])
            require(self.runtime[rank]['executablePathReported'],'Native executable path required')
            first=native_resources(row['initialResources']);self.times[rank]=native_resources(row['loadedResources'],first)
            self.ready[rank]=True
        elif kind=='result':
            require(all(self.ready) and rank not in self.pending and not any(self.released) and self.ordinal<4,'Unexpected result')
            fields(row,'command step execution resourcesBeforeRequest resourcesAfterRequest','result')
            exact(row['command'],command,'Result command differs')
            _,_,history=request_identity(command['epoch'],ref.prompt)
            expected=dict(ordinal=self.ordinal,excludedWarmup=self.ordinal==0,requestID=str(uuid.UUID(command['epoch'])).upper(),
                recordedRequestFingerprint=history,promptFileSHA256=REFERENCE_PINS['prompt.json'])
            exact(row['step'],expected,'Step identity differs')
            before=native_resources(row['resourcesBeforeRequest'],self.times[rank])
            after=native_resources(row['resourcesAfterRequest'],before);self.times[rank]=after
            self.pending[rank]=copy.deepcopy(row)
        elif kind=='released':
            require(self.ordinal==4 and not self.pending and not self.released[rank],'Release preceded four results')
            expected=dict(completedRequestCount=4,modelLoadCount=1,modelReleased=True,allRequestStateRetired=True,
                correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False)
            fields(row,' '.join(expected)+' memory resourcesAfterRelease','released')
            for key,value in expected.items():exact(row[key],value,'Release '+key)
            phases=['before_resident_stage_load','resident_stage_loaded_no_request_state']+[
                'resident_request_%d_retired_weights_resident'%i for i in range(4)]+['resident_stage_released_cache_cleared']
            require(type(row['memory']) is list and len(row['memory'])==7,'Seven release memory records required')
            peak=0
            for item,phase in zip(row['memory'],phases):
                fields(item,'phase activeMLXBytes cachedMLXBytes peakMLXBytesSinceProcessStart','memory')
                exact(item['phase'],phase,'Memory phase');active=integer(item['activeMLXBytes']);integer(item['cachedMLXBytes'])
                current=integer(item['peakMLXBytesSinceProcessStart']);require(current>=max(active,peak),'Peak regressed');peak=current
            require(row['memory'][-1]['cachedMLXBytes']==0,'Cache not cleared')
            self.times[rank]=native_resources(row['resourcesAfterRelease'],self.times[rank]);self.released[rank]=True
        elif kind=='stopped':
            require(all(self.released) and not self.stopped[rank],'Stopped before release')
            exact(row,dict(completedRequestCount=4,modelReleased=True,allRequestStateRetired=True,explicitShutdownAccepted=True,
                correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,
                independentNumericalComparisonPerformed=False),'Stopped differs');self.stopped[rank]=True
        else:raise ValueError('Unexpected event')
        self.raw_hashes[rank]=self.capture(rank,event)

    def numerical(self,command,events):
        require(len(events)==2 and set(self.pending)=={0,1},'Both rank results required')
        ref=self.reference;a=self.a;epoch=command['epoch'];policy='serial_v1'
        recorded,simple,history=wire.request(a,ref.prompt,epoch)
        summary=dict(profileFingerprint=PROFILE_SHA256,requestFingerprint=simple,recordedRequestFingerprint=history,
            promptFileSHA256=REFERENCE_PINS['prompt.json'],promptTokenIDsSHA256=ref.evidence['promptTokenIDsSHA256'],
            arithmeticEnvironmentSHA256=ref.evidence['arithmeticEnvironmentSHA256'],argmaxTokenID=ref.token,finalLogits=ref.logits)
        identities=[storage.identity(a,rank,self.loads[rank],summary) for rank in (0,1)]
        descriptor=wire.agreement(a,epoch,policy,recorded,summary,self.loads)
        fp=wire.fingerprint(a,'qwen-profiled-prefill-start-agreement-v1',canonical(descriptor))
        executions=[]
        for rank in (0,1):
            row=self.pending[rank];outer=row['execution']
            expected=dict(ordinal=self.ordinal,excludedWarmup=self.ordinal==0,epoch=epoch,request=recorded,
                promptFileSHA256=REFERENCE_PINS['prompt.json'],agreement=descriptor,execution=outer.get('execution'),weightsRemainResident=True)
            exact(outer,expected,'Resident request wrapper differs')
            x=outer['execution'];executions.append(x)
            expected=dict(kind='qwen_long_prefill_rank_request',schemaVersion=1,correctnessOnly=True,
                throughputMeasurementValid=False,interprocessTransportUsed=True,physicalTransferQualified=False,
                independentNumericalComparisonPerformed=False,profile=PROFILE,profileFingerprint=PROFILE_SHA256,
                agreementFingerprint=fp,identity=identities[rank],readiness=wire.readiness(a,fp),frames=x.get('frames'),
                actions=trace.expected_actions(rank,policy),selectedTokenID=ref.token,exactTokenPacketJSON=x.get('exactTokenPacketJSON'),
                tokenPacketFingerprint=x.get('tokenPacketFingerprint'),tokenPacketWireBytesSHA256=x.get('tokenPacketWireBytesSHA256'),
                finalDigest=x.get('finalDigest'),completedFrames=16,committedTokens=8192,preparedAheadFrames=0,
                releasedOriginalBoundaryHandles=16,postStopReleaseCompleted=True,allRequestStateRetired=True,
                originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
            if rank==0:expected['timing']=x.get('timing')
            else:expected['localSelection']=pair_wire.token(identities[rank],summary,recorded['steps'][-1]['frame'])
            exact(x,expected,'Native rank execution fields/actions differ')
        frames=wire.check_frames(a,pair_wire,[x['frames'] for x in executions],recorded,summary,self.loads,identities,fp)
        wire.check_token(a,executions,dict(value=descriptor,fingerprint=fp),summary,frames[-1])
        final.check_finals(a,[x['finalDigest'] for x in executions],ref.evidence,summary,self.loads,identities,fp)
        clock=executions[0]['timing'];trace.check_timing(a,clock)
        before=self.pending[0]['resourcesBeforeRequest']['os']['completedNanoseconds']
        after=self.pending[0]['resourcesAfterRequest']['os']['startedNanoseconds']
        require(before<=clock['startUptimeNanoseconds']<clock['stopUptimeNanoseconds']
            and clock['stopUptimeNanoseconds']+clock['postStopThroughRequestCloseNanoseconds']<=after,'Rank-zero clock/resource order differs')
        result=dict(elapsed_ns=clock['elapsedNanoseconds'],prompt_tokens=8192,generated_tokens=1,
            source_sha256=digest(canonical([self.raw_hashes[0],self.raw_hashes[1]])))
        self.results.append(dict(command=copy.deepcopy(command),measurement=result,agreementFingerprint=fp,
            bothFinalStateDigestsMatch=True,finalLogitDigestMatches=True,selectedTokenID=ref.token,
            candidateRawNumericalBytesIndependentlyReconstructed=False,externalTTFTMeasured=False,performanceQualified=False))
        self.pending.clear();self.ordinal+=1
        return copy.deepcopy(result)
