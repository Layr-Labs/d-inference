"""Two-record identity/lifecycle scope only; this is not a numerical oracle."""
import hashlib
from pathlib import Path

from binding_common import fields, integer, parse, pin, require, same
from reference_inputs import ARTIFACT, CONFIGURATION, MANIFEST


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def expected_identity(job, tokens):
    profile = dict(identifier='registered_qwen35_9b_greedy_generation_v1', vocabularySize=248320,
        hiddenSize=4096, activationDType='bfloat16', maximumPromptTokens=8192,
        maximumChunkTokens=512, maximumOutputTokens=128, maximumContextTokens=8320)
    profile['fingerprint'] = digest('|'.join(['qwen-stage-generation-profile-v1',
        profile['identifier'], '248320', '4096', 'bfloat16', '8192', '512', '128', '8320']))
    prompt = digest(','.join(map(str, tokens)))
    request = digest('\n'.join(['qwen-stage-generation-request-v1', profile['fingerprint'], job['request_id'],
        'prompt='+prompt, 'chunk=512', 'output=128', 'stop=']))
    return dict(requestID=job['request_id'].upper(), requestFingerprint=request, profile=profile,
                promptFileSHA256=job['prompt_sha256'], promptTokenIDsSHA256=prompt,
                requestedOutputCount=128, maximumTokens=8320, stopTokenIDs=[])


def require_identity(value, expected):
    for name, wanted in expected.items():
        same(value.get(name), wanted, name)


def admitted(raw, expected):
    require(0 < len(raw) <= 16*1024**2, 'Admitted record exceeds native cap')
    value = fields(parse(raw), 'kind schemaVersion verifiedModelLoaded freshRequestStateCreated '
        'correctnessOnly throughputMeasurementValid requestID requestFingerprint profile promptFileSHA256 '
        'promptTokenIDsSHA256 manifestSHA256 artifactSHA256 configurationSHA256 planSHA256 '
        'requestedOutputCount maximumTokens stopTokenIDs', 'admitted')
    require_identity(value, expected)
    for name, wanted in dict(kind='qwen_full_generation_reference_admitted', schemaVersion=1,
            verifiedModelLoaded=False, freshRequestStateCreated=False, correctnessOnly=True,
            throughputMeasurementValid=False, manifestSHA256=MANIFEST, artifactSHA256=ARTIFACT,
            configurationSHA256=CONFIGURATION).items():
        same(value[name], wanted, name)
    pin(value['planSHA256'])
    return value


def report(raw, expected, first, pid, bundle):
    require(0 < len(raw) <= 16*1024**2, 'Report exceeds native cap')
    value = fields(parse(raw), 'kind schemaVersion completed modelReleased allRequestStateRetired '
        'verifiedFullModelLoads freshFullModelRequests correctnessOnly throughputMeasurementValid '
        'physicalTransferQualified candidateNumericalComparisonPerformed execution resources memory runtime', 'report')
    flags = dict(kind='qwen_full_generation_reference_report', schemaVersion=1, completed=True,
        modelReleased=True, allRequestStateRetired=True, verifiedFullModelLoads=1, freshFullModelRequests=1,
        correctnessOnly=True, throughputMeasurementValid=False, physicalTransferQualified=False,
        candidateNumericalComparisonPerformed=False)
    for name, wanted in flags.items():
        same(value[name], wanted, name)
    execution = fields(value['execution'], 'schema source sourceLoad promptFileSHA256 promptTokenIDsSHA256 '
        'requestID requestFingerprint profile promptCount chunkSize requestedOutputCount maximumTokens '
        'stopTokenIDs requirements selectedTokenIDs selectedTokenIDsSHA256 finishReason completedFrames '
        'committedTokens tokens finalLogits finalState timing finalStateCaptures allRequestStateRetired '
        'modelRemainsResident fullVocabularyValuesRetainedForEveryToken mtpEnabled correctnessOnly '
        'candidateNumericalComparisonPerformed physicalTransferQualified', 'execution')
    require_identity(execution, expected)
    for name, wanted in dict(schema='qwen_full_generation_reference_v1', promptCount=8192, chunkSize=512,
            finishReason='length', completedFrames=143, committedTokens=8319, finalStateCaptures=1,
            allRequestStateRetired=True, modelRemainsResident=True,
            fullVocabularyValuesRetainedForEveryToken=False, mtpEnabled=False, correctnessOnly=True,
            candidateNumericalComparisonPerformed=False, physicalTransferQualified=False).items():
        same(execution[name], wanted, name)
    selected = execution['selectedTokenIDs']
    require(type(selected) is list and len(selected) == 128, 'Incomplete selected token sequence')
    for token in selected:
        integer(token, 'selected token', 0, 248319)
    require(execution['selectedTokenIDsSHA256'] == digest(','.join(map(str, selected))), 'Selected token list hash differs')
    require(type(execution['tokens']) is list and len(execution['tokens']) == 128,
            'Incomplete per-token evidence')
    for index, token in enumerate(execution['tokens']):
        require(type(token) is dict, 'Token evidence must be an object')
        same(token.get('outputOrdinal'), index, 'output ordinal')
        same(token.get('committedTokens'), 8192+index, 'token frontier')
        same(token.get('tokenID'), selected[index], 'token list/evidence binding')
    source = fields(execution['source'], 'artifactAggregateSHA256 sourceConfigurationSHA256 '
        'sourceParameterLayoutSHA256 planSHA256 arithmeticEnvironmentSHA256 bf16ConversionEnabled '
        'embeddingActivationDType sourceModelTensorBytes layerCount vocabularySize', 'source')
    for name, wanted in dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
            planSHA256=first['planSHA256'], bf16ConversionEnabled=True, embeddingActivationDType='bfloat16',
            sourceModelTensorBytes=5038041600, layerCount=32, vocabularySize=248320).items():
        same(source[name], wanted, name)
    pin(source['sourceParameterLayoutSHA256']); pin(source['arithmeticEnvironmentSHA256'])
    for name in ('sourceLoad', 'requirements', 'finalLogits', 'finalState', 'timing'):
        require(type(execution[name]) is dict and execution[name], 'Missing reference evidence object: '+name)
    for name, wanted in dict(configurationSHA256=CONFIGURATION, verifiedAggregateSHA256=ARTIFACT,
            tensorCount=927, sourceTensorCount=927, loadedTensorBytes=5038041600,
            sourceModelTensorBytes=5038041600).items():
        same(execution['sourceLoad'].get(name), wanted, 'sourceLoad.'+name)
    same(execution['requirements'].get('requestFingerprint'), expected['requestFingerprint'], 'requirements request')
    same(execution['requirements'].get('maximumTokens'), 8320, 'requirements capacity')
    same(execution['finalState'].get('committedTokens'), 8319, 'final state frontier')
    require(type(execution['finalState'].get('entries')) is list
            and len(execution['finalState']['entries']) == 72, 'Final state coverage is incomplete')
    pin(execution['finalState'].get('fingerprint'))
    logits = execution['finalLogits']
    for name, wanted in dict(shape=[1,248320], dtype='bfloat16', byteCount=496640).items():
        same(logits.get(name), wanted, 'finalLogits.'+name)
    pin(logits.get('logicalBytesSHA256'))
    require(type(logits.get('values')) is list and len(logits['values']) == 248320
            and all(type(x) in (int, float) for x in logits['values']), 'Full final vocabulary row is missing')
    resources = fields(value['resources'], 'policy budget authorizedTensorCount observationCount '
        'minimumActualFreeBytes maximumObservedActiveBytes requestResourceAdmissionPerformed '
        'actualAllocatorBoundsUsed reclaimableUsedForAdmission wholeProcessPeakBoundEstablished', 'resources')
    for name, wanted in dict(policy='qwen_full_generation_reference_resources_v1', authorizedTensorCount=927,
            requestResourceAdmissionPerformed=True, actualAllocatorBoundsUsed=True,
            reclaimableUsedForAdmission=False, wholeProcessPeakBoundEstablished=False).items():
        same(resources[name], wanted, name)
    integer(resources['observationCount'], 'observation count', 1)
    integer(resources['minimumActualFreeBytes'], 'native minimum actual free', 6*1024**3)
    integer(resources['maximumObservedActiveBytes'], 'maximum active')
    require(type(resources['budget']) is dict, 'Missing named resource budget')
    same(resources['budget'].get('requestFingerprint'), expected['requestFingerprint'], 'budget request')
    same(resources['budget'].get('planFingerprint'), first['planSHA256'], 'budget Plan')
    require(type(value['memory']) is list and len(value['memory']) == 2
            and all(type(row) is dict for row in value['memory']), 'Missing load/release memory observations')
    runtime = value['runtime']
    require(type(runtime) is dict, 'Missing runtime report')
    same(runtime.get('processID'), pid, 'native PID')
    same(runtime.get('mainBundlePath'), str(bundle), 'reported bundle path')
    for name in ('executablePath', 'mainBundleResourcePath'):
        if name in runtime:
            same(runtime[name], str(bundle/('cluster-inference' if name == 'executablePath' else '')), name)
    for name in ('binaryOrBundleHashVerifiedByNative', 'providerEligibilityEstablished', 'recommendedWorkingSetUsedForAdmission'):
        same(runtime.get(name), False, name)
    return value
