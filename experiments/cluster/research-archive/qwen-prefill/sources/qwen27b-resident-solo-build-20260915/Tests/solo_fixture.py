"""Model-free fabricated receipts, never usable as native qualification input."""
import hashlib
import uuid
from solo_contract import ARITHMETIC, PLAN
from reference_contract import expected_identity as reference_identity


def receipts(expected):
    ids=[expected['requestID']]+[str(uuid.UUID(int=x)).upper() for x in (2,3,4)]
    fingerprints=[reference_identity(dict(expected.job,request_id=x.lower()),expected.tokens)['requestFingerprint'] for x in ids]
    first=dict(kind='qwen_resident_solo_generation_admitted',schemaVersion=1,verifiedModelLoaded=False,
        freshRequestStateCreated=False,canonicalDeviceExclusionHeld=True,warmupCount=1,measuredCount=3,
        requestedOutputCount=128,maximumTokens=8320,requestIDs=ids,requestFingerprints=fingerprints,
        profile=expected['profile'],promptFileSHA256=expected['promptFileSHA256'],
        promptTokenIDsSHA256=expected['promptTokenIDsSHA256'],expectedTokenFileSHA256=expected.job['expected_sha256'],
        manifestSHA256=expected.model.manifest,artifactSHA256=expected.model.artifact,
        configurationSHA256=expected.model.configuration,referencePlanSHA256=PLAN,processLifetimeSeconds=300,
        perRequestMaximumSeconds=120,prefixReuse=False,mtpEnabled=False,externalTTFTMeasured=False)
    rows=[]
    for index in range(4):
        start=(1+index*4)*10**9;stamps=[start+10**9+x*10**6 for x in range(128)]
        timing=dict(clock='DispatchTime.uptimeNanoseconds.same_process',requestStartNanoseconds=start,
            selectedTokenNanoseconds=stamps,retiredNanoseconds=start+2*10**9,prefillSeconds=1.0,
            decodeSeconds=0.127,prefillTokensPerSecond=8192.0,decodeTokensPerSecond=1000.0,
            includesLoading=False,includesSourceAndResourceAdmission=False,includesFreshStateConstruction=True,
            includesPerForwardOwnershipValidation=True,includesDiagnosticRowOrStateCapture=False,
            includesTransport=False,externalTTFTMeasured=False)
        execution=dict(requestID=ids[index],requestFingerprint=fingerprints[index],selectedTokenIDs=expected.expected,
            selectedTokenIDsSHA256=hashlib.sha256(','.join(map(str,expected.expected)).encode()).hexdigest(),
            completedFrames=143,committedTokens=8319,timing=timing,promptCount=8192,chunkSize=512,
            requestedOutputCount=128,finishReason='length',expectedTokenSequenceMatched=True,
            allRequestStateRetired=True,modelRemainsResident=True,prefixReuse=False,mtpEnabled=False,
            fullVocabularyRowsCaptured=False,stateSnapshotsCaptured=False,independentFullRowStateComparisonPerformed=False)
        rows.append(dict(ordinal=index,isWarmup=index==0,execution=execution))
    source=dict(artifactAggregateSHA256=expected.model.artifact,sourceConfigurationSHA256=expected.model.configuration,
        sourceParameterLayoutSHA256='a'*64,planSHA256=PLAN,arithmeticEnvironmentSHA256=ARITHMETIC,
        bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',sourceModelTensorBytes=5_038_041_600,
        layerCount=32,vocabularySize=248320)
    loaded=dict(configurationSHA256=expected.model.configuration,verifiedAggregateSHA256=expected.model.artifact,
        parameterLayoutSHA256='a'*64,tensorCount=927,sourceTensorCount=927,loadedTensorBytes=5_038_041_600,
        sourceModelTensorBytes=5_038_041_600,bf16ConversionEnabled=True)
    resource=dict(policy='qwen_full_generation_reference_resources_v1',authorizedTensorCount=927,observationCount=1,
        minimumActualFreeBytes=6*1024**3,maximumObservedActiveBytes=1,requestResourceAdmissionPerformed=True,
        actualAllocatorBoundsUsed=True,reclaimableUsedForAdmission=False,wholeProcessPeakBoundEstablished=False,
        budget=dict(requestFingerprint=fingerprints[0],planFingerprint=PLAN))
    kernel=dict(gatedDeltaLayers=24,fusedProjectionLayers=24,warmupDispatch=dict(nativePrefillCalls=384,
        nativeDecodeCalls=3048,operationsFallbackCalls=0,invalidGeometryCalls=0),configuredQueryBlockSize=128,
        queryBlockDispatchIndependentlyCounted=False,measuredRequestDispatchObservationEnabled=False,
        optimizedAgainstAllPossibleSoloPolicies=False)
    final=dict(kind='qwen_resident_solo_generation_report',schemaVersion=1,completed=True,verifiedFullModelLoads=1,
        warmupCount=1,measuredCount=3,freshRequestsAdmitted=4,modelReleased=True,allRequestStateRetired=True,
        prefixReuse=False,mtpEnabled=False,allocatorPolicy='disable_freed_buffer_cache_v1',
        unusedDiagnosticAllowanceStillReserved=True,independentNumericalComparisonPerformed=False,
        physicalOrPerformanceQualificationEstablished=False,externalTTFTMeasured=False,source=source,sourceLoad=loaded,
        expectedTokenFileSHA256=expected.job['expected_sha256'],kernelEligibility=kernel,requests=rows,
        resources=resource,memory=[{} for _ in range(7)],runtime=dict(processID=1,mainBundlePath=expected.job['deployment'],
        binaryOrBundleHashVerifiedByNative=False,providerEligibilityEstablished=False,recommendedWorkingSetUsedForAdmission=False))
    return first,final
