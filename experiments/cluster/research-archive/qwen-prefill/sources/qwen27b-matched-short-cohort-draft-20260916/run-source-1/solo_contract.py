"""Closed progressive solo cohort validator. No missing row/state evidence inferred."""
import hashlib
import math
import uuid
from binding_common import fields, integer, parse, pin, require, same
from reference_contract import expected_identity as reference_identity

PLAN = '8e1408f4f044b0fa6f97ae9b997d575797fe1d22036ddb68409e2aeb349949ed'
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


def measured_count(expected):
    return integer(expected.job.get("measured_count", 3), "measured count", 1, 3)


def admitted(raw, expected):
    require(0 < len(raw) <= 128*1024, 'Solo admitted record bound')
    value = fields(parse(raw), 'kind schemaVersion verifiedModelLoaded freshRequestStateCreated '
        'canonicalDeviceExclusionHeld warmupCount measuredCount requestedOutputCount maximumTokens '
        'requestIDs requestFingerprints profile promptFileSHA256 promptTokenIDsSHA256 expectedTokenFileSHA256 '
        'manifestSHA256 artifactSHA256 configurationSHA256 referencePlanSHA256 processLifetimeSeconds '
        'perRequestMaximumSeconds prefixReuse mtpEnabled externalTTFTMeasured', 'solo admitted')
    same_fields(value, dict(kind='qwen_resident_solo_generation_admitted', schemaVersion=1,
        verifiedModelLoaded=False, freshRequestStateCreated=False, canonicalDeviceExclusionHeld=True,
        warmupCount=1, measuredCount=measured_count(expected), requestedOutputCount=128, maximumTokens=8320,
        profile=expected['profile'], promptFileSHA256=expected['promptFileSHA256'],
        promptTokenIDsSHA256=expected['promptTokenIDsSHA256'], expectedTokenFileSHA256=expected.job['expected_sha256'],
        manifestSHA256=expected.model.manifest, artifactSHA256=expected.model.artifact,
        configurationSHA256=expected.model.configuration, referencePlanSHA256=PLAN,
        processLifetimeSeconds=300, perRequestMaximumSeconds=120, prefixReuse=False,
        mtpEnabled=False, externalTTFTMeasured=False))
    ids, fingerprints = value['requestIDs'], value['requestFingerprints']
    require(type(ids) is list and len(ids) == 1+measured_count(expected) and len(set(ids)) == len(ids)
        and type(fingerprints) is list and len(fingerprints) == len(ids), 'Configured unique admitted histories')
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


def validate_kernel(value):
    kernel = fields(value, 'gatedDeltaLayers fusedProjectionLayers warmupDispatch configuredQueryBlockSize '
        'queryBlockDispatchIndependentlyCounted measuredRequestDispatchObservationEnabled optimizedAgainstAllPossibleSoloPolicies', 'kernel')
    same_fields(kernel, dict(gatedDeltaLayers=48, fusedProjectionLayers=48, configuredQueryBlockSize=128,
        queryBlockDispatchIndependentlyCounted=False, measuredRequestDispatchObservationEnabled=False,
        optimizedAgainstAllPossibleSoloPolicies=False))
    same(kernel['warmupDispatch'], dict(nativePrefillCalls=768,nativeDecodeCalls=6096,
        operationsFallbackCalls=0,invalidGeometryCalls=0), 'actual warmup dispatch')
    return kernel


def validate_source(source, loaded, expected):
    source = fields(source, 'artifactAggregateSHA256 sourceConfigurationSHA256 sourceParameterLayoutSHA256 '
        'planSHA256 arithmeticEnvironmentSHA256 bf16ConversionEnabled embeddingActivationDType '
        'sourceModelTensorBytes layerCount vocabularySize', 'source')
    same_fields(source,dict(artifactAggregateSHA256=expected.model.artifact,
        sourceConfigurationSHA256=expected.model.configuration,planSHA256=PLAN,arithmeticEnvironmentSHA256=ARITHMETIC,
        bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',sourceModelTensorBytes=expected.model.source_bytes,
        layerCount=expected.model.layers,vocabularySize=248320))
    pin(source['sourceParameterLayoutSHA256'])
    require(type(loaded) is dict, 'Source load receipt missing')
    same_fields(loaded,dict(configurationSHA256=expected.model.configuration,
        verifiedAggregateSHA256=expected.model.artifact,parameterLayoutSHA256=source['sourceParameterLayoutSHA256'],
        tensorCount=expected.model.tensor_count,sourceTensorCount=expected.model.tensor_count,loadedTensorBytes=expected.model.source_bytes,sourceModelTensorBytes=expected.model.source_bytes,
        bf16ConversionEnabled=True))


def validate_request(row, expected, first, index):
    token_hash = hashlib.sha256(','.join(map(str,expected.expected)).encode()).hexdigest()
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
    return timing(row['execution']['timing'])


def report(raw, expected, first, pid, bundle):
    require(0 < len(raw) <= 128*1024, 'Solo report bound')
    value = fields(parse(raw), 'kind schemaVersion completed verifiedFullModelLoads warmupCount measuredCount '
        'freshRequestsAdmitted modelReleased allRequestStateRetired prefixReuse mtpEnabled allocatorPolicy '
        'unusedDiagnosticAllowanceStillReserved independentNumericalComparisonPerformed '
        'physicalOrPerformanceQualificationEstablished externalTTFTMeasured source sourceLoad expectedTokenFileSHA256 '
        'kernelEligibility requests resources memory runtime', 'solo report')
    same_fields(value, dict(kind='qwen_resident_solo_generation_report', schemaVersion=1, completed=True,
        verifiedFullModelLoads=1, warmupCount=1, measuredCount=measured_count(expected), freshRequestsAdmitted=1+measured_count(expected),
        modelReleased=True, allRequestStateRetired=True, prefixReuse=False, mtpEnabled=False,
        allocatorPolicy='disable_freed_buffer_cache_v1', unusedDiagnosticAllowanceStillReserved=True,
        independentNumericalComparisonPerformed=False, physicalOrPerformanceQualificationEstablished=False,
        externalTTFTMeasured=False, expectedTokenFileSHA256=expected.job['expected_sha256']))
    kernel = validate_kernel(value['kernelEligibility'])
    validate_source(value['source'], value['sourceLoad'], expected)
    requests = value['requests']; require(type(requests) is list and len(requests)==1+measured_count(expected),'Configured completed requests')
    previous = 0
    for index,row in enumerate(requests):
        start,end=validate_request(row, expected, first, index)
        require(start>=previous,'Request overlaps prior retirement');previous=end
    resources=fields(value['resources'],'policy budget authorizedTensorCount observationCount minimumActualFreeBytes '
        'maximumObservedActiveBytes requestResourceAdmissionPerformed actualAllocatorBoundsUsed reclaimableUsedForAdmission '
        'wholeProcessPeakBoundEstablished','resource receipt')
    same_fields(resources,dict(policy='qwen_full_generation_reference_resources_v1',authorizedTensorCount=expected.model.tensor_count,
        requestResourceAdmissionPerformed=True,actualAllocatorBoundsUsed=True,reclaimableUsedForAdmission=False,
        wholeProcessPeakBoundEstablished=False))
    integer(resources['observationCount'],'resource observations',1)
    integer(resources['minimumActualFreeBytes'],'minimum actual free',6*1024**3)
    integer(resources['maximumObservedActiveBytes'],'maximum active',0)
    require(type(resources['budget']) is dict,'Resource budget missing')
    same_fields(resources['budget'],dict(requestFingerprint=first['requestFingerprints'][0],planFingerprint=PLAN))
    require(type(value['memory']) is list and len(value['memory'])==4+measured_count(expected)
        and all(type(v) is dict for v in value['memory']),'Load, configured retirements and model release memory observations')
    runtime=value['runtime'];require(type(runtime) is dict,'Runtime receipt missing')
    same_fields(runtime,dict(processID=pid,mainBundlePath=str(bundle),binaryOrBundleHashVerifiedByNative=False,
        providerEligibilityEstablished=False,recommendedWorkingSetUsedForAdmission=False))
    for key in ('executablePath','mainBundleResourcePath'):
        if key in runtime:same(runtime[key],str(bundle/('cluster-inference' if key=='executablePath' else '')),key)
    return value
