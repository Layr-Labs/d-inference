"""Strict run/role/lifecycle acceptance, deliberately separate from model numerics."""
import hashlib,math,re,uuid
from binding_common import require
from gemma_inputs import REMOTE
from dense_contract import EMBEDDING_SHA256,target_summary,target_terms
from embedding_contract import assistant_load_completion
from control_contract import validate_control_metrics

def sha(raw):return hashlib.sha256(raw).hexdigest()
def digest(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None

def verification_depth(local):
    depth=local['maximumDraftTokens']
    require(type(depth) is int and depth in (1,2),'Chosen verification depth must be one or two')
    return depth

def validate_metadata_depth(value,local):
    require(type(value['maximumDraftTokens']) is int
        and value['maximumDraftTokens']==verification_depth(local)
        and type(value['maximumBufferedProposals']) is int and value['maximumBufferedProposals']==5,
        'Metadata chosen depth/producer queue differs')

def validate_verification_widths(widths,local):
    # The producer may still grant two and retain five proposals at chosen depth
    # one. This bounds actual target verification, not producer credit capacity.
    depth=verification_depth(local)
    require(type(widths) is list and widths and widths[0]==1
        and all(type(w) is int and 1<=w<=depth+1 for w in widths),
        'Verification widths exceed the chosen depth')

def validate_inputs(job,local,wrapper,job_sha,local_sha,run):
    require(set(wrapper)=={'schema','role','localMTPJob','localMTPJobSHA256','targetNativeSHA256','assistantNativeSHA256','embeddingIdentitySHA256'},'Remote job fields')
    role=wrapper['role'];require(role in ('target','assistant'),'Physical role')
    require(wrapper['schema']=='gemma4_remote_mtp_cohort_job_v1' and wrapper['localMTPJob']==str(run/'local-mtp.json')
        and wrapper['localMTPJobSHA256']==local_sha,'Remote local job identity')
    require(wrapper['embeddingIdentitySHA256']==EMBEDDING_SHA256,'Registered selected embedding identity')
    require(all(digest(wrapper[k]) for k in ['targetNativeSHA256','assistantNativeSHA256','embeddingIdentitySHA256']),'Native/embedding digest')
    require(set(local)=={'schema','benchmarkJob','benchmarkJobSHA256','assistantModelDirectory','assistantMetadataDirectory','maximumDraftTokens','captureEvidence'},'Local input fields')
    require(local['schema']=='gemma4_local_mtp_cohort_job_v1' and local['benchmarkJob']==str(run/'job.json') and local['benchmarkJobSHA256']==job_sha
        and type(local['captureEvidence']) is bool,'Depth/local input')
    verification_depth(local)
    require(local['assistantModelDirectory']=='/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1'
        and local['assistantMetadataDirectory']==str(REMOTE/'assistant-metadata'),'Registered assistant directories')
    require(set(job)=={'schema','mode','modelDirectory','metadataDirectory','promptFile','promptFileSHA256','outputDirectory',
        'buildIdentitySHA256','requestIDs','membershipEpoch','promptCount','chunkSize','outputCount','cut','prefillPolicy','timeoutSeconds','residualDType','captureEvidence'},'Ordinary job fields')
    require(job['schema']=='gemma4_resident_benchmark_v1' and job['mode']=='full' and job['promptCount'] in [128,4096]
        and (job['chunkSize'],job['outputCount'],job['cut'],job['prefillPolicy'],job['timeoutSeconds'],job['residualDType'])==(64,16,7,'serial',300,'bfloat16')
        and job['captureEvidence'] is False,'Closed ordinary metadata workload')
    require(job['modelDirectory']=='/Users/developer/DarkbloomDev/models/Gemma4-26B' and job['metadataDirectory']==str(REMOTE/'metadata')
        and job['promptFile']==str(REMOTE/f'prompts/prompt-{job["promptCount"]}.json') and job['outputDirectory']==str(run/'sidecars'),'Exact input/output paths')
    require(job['buildIdentitySHA256']==wrapper['targetNativeSHA256']==wrapper['assistantNativeSHA256'],'Same actual build required')
    require(len(job['requestIDs'])==len(set(job['requestIDs']))==4 and digest(job['promptFileSHA256']),'Fresh four requests')
    require(str(uuid.UUID(job['membershipEpoch']))==job['membershipEpoch'].lower()
        and all(str(uuid.UUID(x))==x.lower() for x in job['requestIDs']),'Canonical epoch/request UUIDs')
    return role

def validate_result(value,job,local,wrapper):
    role=wrapper['role'];target=role=='target'
    require(value['schema']=='gemma4_remote_mtp_'+role+'_cohort_v1' and value['configuration']==wrapper,'Result role/input')
    require(value['targetRank']==1 and value['assistantRank']==0 and value['warmupRequests']==1 and value['measuredRequests']==3,'Topology/cohort')
    for key in ['modelReleased','nativeExecuted','collectiveCreated','collectiveReleased']:require(value[key] is True,'Missing completed native fact: '+key)
    for key in ['encryptedRDMAEstablished','numericalComparisonPerformed','servingEnabled','physicalProcessOrLeaseRetirementEstablished']:
        require(value[key] is False,'Unestablished claim: '+key)
    validate_control_metrics(value)
    require(digest(value['scopeSHA256']) and value['nativeCacheBytesAfterRelease']==0
        and value['guardMetrics']['schema']=='gemma4_guard_wall_counters_v1','Scope/cache/fresh guard policy')
    require(len(value['samples'])==4,'Four actual requests required')
    if target:
        target_summary(value.get('denseProjection'))
        target_terms(value['remoteResources']['baseTerms'])
        require(value['ordinaryJob']==job and value['assistantLoadedOnTarget'] is False,'Full target ownership')
        resource=value['resources'];extra=value['remoteResources']
        require(resource['completedTensorCount']==resource['selectedTensorCount']==1339 and resource['minimumActualFreeBytes']>=6*1024**3
            and resource['operationalResourceChecksApplied'] is True and resource['actualAllocatorBoundsUsed'] is True
            and resource['newServingActivationFloorEstablished'] is False,'Original target resource owner')
        require(extra['policy']=='gemma4_mtp_remote_target_resources_v1' and extra['observations']>0
            and extra['minimumActualFreeBytes']>=6*1024**3 and extra['hostBytes']==16*1024**2+32768,'Target added resource observation')
        for key in ['assistantLoadedOnTarget','servingFloorChanged','wholeProcessPeakBoundEstablished','physicalRetirementEstablished']:require(extra[key] is False,'Target resource claim')
        for field,total in [('baseTerms','baseNativeBytes'),('verificationTerms','verificationNativeBytes')]:
            rows=extra[field];require(len({x['name'] for x in rows})==len(rows) and rows,'Resource names')
            require(all(type(x['logicalBytes']) is int and x['logicalBytes']>0 and type(x['allocationBound']) is int and x['allocationBound']>=x['logicalBytes'] for x in rows)
                and sum(x['allocationBound'] for x in rows)==extra[total],'Resource named allocation sum')
    else:
        require('denseProjection' not in value,'Assistant must not activate target projection')
        require(value['fullTargetLoaded'] is False,'Assistant must not load full target')
        resource=value['resources'];load=value['assistantLoad']
        require(load['artifactSHA256']=='d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34'
            and load['tensorCount']==94 and load['tensorBytes']==236114440 and load['allActualParametersReplaced'] is True,'Registered assistant load')
        assistant_load_completion(value)
        require(resource['placement']=='remoteAssistant' and resource['observationCount']>0
            and resource['minimumActualFreeBytes']>=6*1024**3 and resource['servingFloorChanged'] is False
            and resource['reclaimableUsedForAdmission'] is False,'Assistant retained owner')
    token_sets=[]
    for index,s in enumerate(value['samples']):
        require(s['ordinal']==index and s['requestID']==job['requestIDs'][index].lower() and digest(s['requestSHA256']),'Request identity')
        if not target:
            require(s['originalServiceReleased'] is True and s['branchRootsReleased'] is True and s['targetTokensIndependentlyVerified'] is False
                and s['physicalOwnerRetirementEstablished'] is False and digest(s['wireScopeSHA256']),'Assistant release evidence');continue
        require(s['warmup'] is (index==0) and s['requestStateRetired'] is True and digest(s['scopeSHA256']),'Target request lifecycle')
        require(s['maximumDraftTokens']==2 and s['maximumBufferedProposals']==5 and s['mtpEnabled'] is True and s['remoteAssistant'] is True,'Producer depth/queue envelope')
        require(s['targetBatchNumericsQualified'] is False and s['physicalOwnerRetirementEstablished'] is False,'Target quality claim')
        tokens=s['selectedTokenIDs'];token_sets.append(tokens)
        require(len(tokens)==16 and all(type(x) is int and 0<=x<262144 for x in tokens)
            and s['selectedTokenIDsSHA256']==sha(','.join(map(str,tokens)).encode()),'Actual selected tokens')
        widths=s['verificationWidths'];accepted=s['acceptedPrefixes']
        validate_verification_widths(widths,local)
        require(len(widths)==len(accepted)
            and all(type(a) is int and 0<=a<w for a,w in zip(accepted,widths)) and len(widths)+sum(accepted)==15
            and s['committedTokens']==job['promptCount']+15,'Accepted-prefix/frontier accounting')
        require(s['offeredProposals']==sum(w-1 for w in widths) and s['acceptedProposals']==sum(accepted)
            and s['generatedProposals']>=s['offeredProposals'] and 0<=s['reusedProposalsOffered']<=s['offeredProposals'],'Proposal counters')
        for phase,count in [('prefill',job['promptCount']),('decode',15)]:
            ns=s[phase+'Nanoseconds'];tps=s[phase+'TPS']
            require(type(ns) is int and ns>0 and type(tps) in [float,int] and math.isfinite(tps)
                and math.isclose(tps,count*1e9/ns,rel_tol=1e-12),'Same-process duration arithmetic')
        require(s['timingsAreSameProcess'] is True and s['rejectedWorkIncluded'] is True,'Timing semantics')
        ev=s['evidence'];require(ev['outsideGenerationTiming'] is True and ev['capturedBeforeRequestRetirement'] is True
            and ev['numericalComparisonPerformed'] is False,'Evidence capture lifecycle')
        captured=ev.get('finalRow') is not None and ev.get('finalState') is not None
        require(captured is local['captureEvidence'],'Evidence policy')
        if captured:require(ev['finalState']['frontier']==job['promptCount']+15 and len(ev['finalState']['entries'])==90,'Canonical full state')
    if target:require(all(x==token_sets[0] for x in token_sets),'Fresh request token reproducibility')
    return value
