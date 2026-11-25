"""Closed two-record solo cohort validator. No missing row/state evidence inferred."""
import hashlib
import math
import uuid
from binding_common import fields, integer, parse, pin, require, same
from reference_contract import expected_identity as reference_identity

PLAN = '67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f'
ARITHMETIC = '0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74'


class SoloIdentity(dict):
    def __init__(self, job, tokens, expected):
        first = reference_identity(job, tokens)
        super().__init__(first)
        self.job, self.tokens, self.expected, self.model = job, tokens, expected, first.model


def expected_identity(job, tokens, expected):
    require(len(tokens) == 8192 and len(expected) == 128, 'Matched solo input geometry')
    return SoloIdentity(job, tokens, expected)


def same_fields(value, expected):
    for name, wanted in expected.items(): same(value[name], wanted, name)


def admitted(raw, expected):
    require(0 < len(raw) <= 128*1024, 'Solo admitted record bound')
    value = fields(parse(raw), 'kind schemaVersion verifiedModelLoaded freshRequestStateCreated '
        'canonicalDeviceExclusionHeld warmupCount measuredCount requestedOutputCount maximumTokens '
        'requestIDs requestFingerprints profile promptFileSHA256 promptTokenIDsSHA256 expectedTokenFileSHA256 '
        'manifestSHA256 artifactSHA256 configurationSHA256 referencePlanSHA256 processLifetimeSeconds '
        'perRequestMaximumSeconds prefixReuse mtpEnabled externalTTFTMeasured', 'solo admitted')
    same_fields(value, dict(kind='qwen_resident_solo_generation_admitted', schemaVersion=1,
        verifiedModelLoaded=False, freshRequestStateCreated=False, canonicalDeviceExclusionHeld=True,
        warmupCount=1, measuredCount=3, requestedOutputCount=128, maximumTokens=8320,
        profile=expected['profile'], promptFileSHA256=expected['promptFileSHA256'],
        promptTokenIDsSHA256=expected['promptTokenIDsSHA256'], expectedTokenFileSHA256=expected.job['expected_sha256'],
        manifestSHA256=expected.model.manifest, artifactSHA256=expected.model.artifact,
        configurationSHA256=expected.model.configuration, referencePlanSHA256=PLAN,
        processLifetimeSeconds=300, perRequestMaximumSeconds=120, prefixReuse=False,
        mtpEnabled=False, externalTTFTMeasured=False))
    ids, fingerprints = value['requestIDs'], value['requestFingerprints']
    require(type(ids) is list and len(ids) == 4 and len(set(ids)) == 4
        and type(fingerprints) is list and len(fingerprints) == 4, 'Four unique admitted histories')
    same(ids[0], expected['requestID'], 'first pinned request ID')
    for index, identifier in enumerate(ids):
        require(type(identifier) is str and str(uuid.UUID(identifier)).upper() == identifier, 'Native UUID form')
        job = dict(expected.job, request_id=identifier.lower())
        same(fingerprints[index], reference_identity(job, expected.tokens)['requestFingerprint'], 'fresh request fingerprint')
    return value


def timing(value):
    fields(value, 'clock requestStartNanoseconds selectedTokenNanoseconds retiredNanoseconds prefillSeconds '
        'decodeSeconds prefillTokensPerSecond decodeTokensPerSecond includesLoading includesSourceAndResourceAdmission '
        'includesFreshStateConstruction includesPerForwardOwnershipValidation includesDiagnosticRowOrStateCapture '
        'includesTransport externalTTFTMeasured', 'solo timing')
    same_fields(value, dict(clock='DispatchTime.uptimeNanoseconds.same_process', includesLoading=False,
        includesSourceAndResourceAdmission=False, includesFreshStateConstruction=True,
        includesPerForwardOwnershipValidation=True, includesDiagnosticRowOrStateCapture=False,
        includesTransport=False, externalTTFTMeasured=False))
    start = integer(value['requestStartNanoseconds'], 'request start', 0, 2**64-1)
    end = integer(value['retiredNanoseconds'], 'request retirement', 0, 2**64-1)
    stamps = value['selectedTokenNanoseconds']
    require(type(stamps) is list and len(stamps) == 128, '128 committed-token timestamps required')
    for stamp in stamps: integer(stamp, 'token timestamp', 0, 2**64-1)
    require(start < stamps[0] < stamps[-1] <= end and stamps == sorted(stamps), 'Token clock order')
    require(end-start < 120*10**9, 'Request exceeded its fixed bound')
    prefill, decode = (stamps[0]-start)/1e9, (stamps[-1]-stamps[0])/1e9
    for name, wanted in dict(prefillSeconds=prefill, decodeSeconds=decode,
            prefillTokensPerSecond=8192/prefill, decodeTokensPerSecond=127/decode).items():
        got = value[name]
        require(type(got) in (float,int) and math.isfinite(got)
            and math.isclose(got,wanted,rel_tol=1e-12,abs_tol=1e-12), 'Derived timing differs: '+name)
    return start,end


def report(raw, expected, first, pid, bundle):
    require(0 < len(raw) <= 128*1024, 'Solo report bound')
    value = fields(parse(raw), 'kind schemaVersion completed verifiedFullModelLoads warmupCount measuredCount '
        'freshRequestsAdmitted modelReleased allRequestStateRetired prefixReuse mtpEnabled allocatorPolicy '
        'unusedDiagnosticAllowanceStillReserved independentNumericalComparisonPerformed '
        'physicalOrPerformanceQualificationEstablished externalTTFTMeasured source sourceLoad expectedTokenFileSHA256 '
        'kernelEligibility requests resources memory runtime', 'solo report')
    same_fields(value, dict(kind='qwen_resident_solo_generation_report', schemaVersion=1, completed=True,
        verifiedFullModelLoads=1, warmupCount=1, measuredCount=3, freshRequestsAdmitted=4,
        modelReleased=True, allRequestStateRetired=True, prefixReuse=False, mtpEnabled=False,
        allocatorPolicy='disable_freed_buffer_cache_v1', unusedDiagnosticAllowanceStillReserved=True,
        independentNumericalComparisonPerformed=False, physicalOrPerformanceQualificationEstablished=False,
        externalTTFTMeasured=False, expectedTokenFileSHA256=expected.job['expected_sha256']))
    kernel = fields(value['kernelEligibility'], 'gatedDeltaLayers fusedProjectionLayers warmupDispatch configuredQueryBlockSize '
        'queryBlockDispatchIndependentlyCounted measuredRequestDispatchObservationEnabled optimizedAgainstAllPossibleSoloPolicies', 'kernel')
    same_fields(kernel, dict(gatedDeltaLayers=24, fusedProjectionLayers=24, configuredQueryBlockSize=128,
        queryBlockDispatchIndependentlyCounted=False, measuredRequestDispatchObservationEnabled=False,
        optimizedAgainstAllPossibleSoloPolicies=False))
    same(kernel['warmupDispatch'], dict(nativePrefillCalls=384,nativeDecodeCalls=3048,
        operationsFallbackCalls=0,invalidGeometryCalls=0), 'actual warmup dispatch')
    source = fields(value['source'], 'artifactAggregateSHA256 sourceConfigurationSHA256 sourceParameterLayoutSHA256 '
        'planSHA256 arithmeticEnvironmentSHA256 bf16ConversionEnabled embeddingActivationDType '
        'sourceModelTensorBytes layerCount vocabularySize', 'source')
    same_fields(source,dict(artifactAggregateSHA256=expected.model.artifact,
        sourceConfigurationSHA256=expected.model.configuration,planSHA256=PLAN,arithmeticEnvironmentSHA256=ARITHMETIC,
        bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',sourceModelTensorBytes=5_038_041_600,
        layerCount=32,vocabularySize=248320))
    pin(source['sourceParameterLayoutSHA256'])
    require(type(value['sourceLoad']) is dict, 'Source load receipt missing')
    same_fields(value['sourceLoad'],dict(configurationSHA256=expected.model.configuration,
        verifiedAggregateSHA256=expected.model.artifact,parameterLayoutSHA256=source['sourceParameterLayoutSHA256'],
        tensorCount=927,sourceTensorCount=927,loadedTensorBytes=5_038_041_600,sourceModelTensorBytes=5_038_041_600,
        bf16ConversionEnabled=True))
    requests = value['requests']; require(type(requests) is list and len(requests)==4,'Four completed requests')
    previous = 0
    token_hash = hashlib.sha256(','.join(map(str,expected.expected)).encode()).hexdigest()
    for index,row in enumerate(requests):
        fields(row,'ordinal isWarmup execution','cohort request')
        same_fields(row,dict(ordinal=index,isWarmup=index==0))
        execution = fields(row['execution'], 'requestID requestFingerprint selectedTokenIDs selectedTokenIDsSHA256 '
            'completedFrames committedTokens timing promptCount chunkSize requestedOutputCount finishReason '
            'expectedTokenSequenceMatched allRequestStateRetired modelRemainsResident prefixReuse mtpEnabled '
            'fullVocabularyRowsCaptured stateSnapshotsCaptured independentFullRowStateComparisonPerformed','request result')
        same_fields(execution,dict(requestID=first['requestIDs'][index],requestFingerprint=first['requestFingerprints'][index],
            selectedTokenIDs=expected.expected,selectedTokenIDsSHA256=token_hash,completedFrames=143,committedTokens=8319,
            promptCount=8192,chunkSize=512,requestedOutputCount=128,finishReason='length',expectedTokenSequenceMatched=True,
            allRequestStateRetired=True,modelRemainsResident=True,prefixReuse=False,mtpEnabled=False,
            fullVocabularyRowsCaptured=False,stateSnapshotsCaptured=False,independentFullRowStateComparisonPerformed=False))
        start,end=timing(execution['timing']);require(start>=previous,'Request overlaps prior retirement');previous=end
    resources=fields(value['resources'],'policy budget authorizedTensorCount observationCount minimumActualFreeBytes '
        'maximumObservedActiveBytes requestResourceAdmissionPerformed actualAllocatorBoundsUsed reclaimableUsedForAdmission '
        'wholeProcessPeakBoundEstablished','resource receipt')
    same_fields(resources,dict(policy='qwen_full_generation_reference_resources_v1',authorizedTensorCount=927,
        requestResourceAdmissionPerformed=True,actualAllocatorBoundsUsed=True,reclaimableUsedForAdmission=False,
        wholeProcessPeakBoundEstablished=False))
    integer(resources['observationCount'],'resource observations',1)
    integer(resources['minimumActualFreeBytes'],'minimum actual free',6*1024**3)
    integer(resources['maximumObservedActiveBytes'],'maximum active',0)
    require(type(resources['budget']) is dict,'Resource budget missing')
    same_fields(resources['budget'],dict(requestFingerprint=first['requestFingerprints'][0],planFingerprint=PLAN))
    require(type(value['memory']) is list and len(value['memory'])==7
        and all(type(v) is dict for v in value['memory']),'Load, four retirements and model release memory observations')
    runtime=value['runtime'];require(type(runtime) is dict,'Runtime receipt missing')
    same_fields(runtime,dict(processID=pid,mainBundlePath=str(bundle),binaryOrBundleHashVerifiedByNative=False,
        providerEligibilityEstablished=False,recommendedWorkingSetUsedForAdmission=False))
    for key in ('executablePath','mainBundleResourcePath'):
        if key in runtime:same(runtime[key],str(bundle/('cluster-inference' if key=='executablePath' else '')),key)
    return value
