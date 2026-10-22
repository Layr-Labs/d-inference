"""Replay the complete exported final row and validate compact reference history."""
import math
import struct
from audit_common import (ARTIFACT, CONFIG, MANIFEST, LAYOUT, PLAN, ARITHMETIC,
    VOCAB, PROMPT, OUTPUT, CHUNK, FRONTIER, FRAMES, fields, exact, integer, sha,
    parse, profile, token_hash, token_ids, selected_frame)
from audit_state import check_state
from audit_scope import scope_for
from recorded_math import logical_bytes, require

ADMITTED_KEYS = ('kind schemaVersion requestID requestFingerprint profile promptFileSHA256 '
    'promptTokenIDsSHA256 manifestSHA256 artifactSHA256 configurationSHA256 planSHA256 '
    'requestedOutputCount maximumTokens stopTokenIDs verifiedModelLoaded freshRequestStateCreated '
    'correctnessOnly throughputMeasurementValid')
REPORT_KEYS = ('kind schemaVersion completed modelReleased allRequestStateRetired '
    'verifiedFullModelLoads freshFullModelRequests correctnessOnly throughputMeasurementValid '
    'physicalTransferQualified candidateNumericalComparisonPerformed execution resources memory runtime')
EXECUTION_KEYS = ('schema source sourceLoad promptFileSHA256 promptTokenIDsSHA256 requestID '
    'requestFingerprint profile promptCount chunkSize requestedOutputCount maximumTokens stopTokenIDs '
    'requirements selectedTokenIDs selectedTokenIDsSHA256 finishReason completedFrames committedTokens '
    'tokens finalLogits finalState timing finalStateCaptures allRequestStateRetired modelRemainsResident '
    'fullVocabularyValuesRetainedForEveryToken mtpEnabled correctnessOnly '
    'candidateNumericalComparisonPerformed physicalTransferQualified')
TOKEN_KEYS = ('outputOrdinal frame committedTokens tokenID maximumTieCount maximumLogit '
    'logitsShape logitsDType logitsByteCount logitsLogicalBytesSHA256 policy '
    'cpuCrosscheckPolicy nativeSelectionMatchesCapturedFullRow')


def check_reference(raw, context):
    scope = scope_for(context)
    model = scope.model
    ARTIFACT, CONFIG, MANIFEST, LAYOUT, PLAN = (model['artifact'], model['configuration'],
        model['manifest'], model['layout'], scope.plan['fingerprint'])
    VOCAB, PROMPT, OUTPUT, CHUNK = model['vocab'], scope.prompt, scope.output, scope.chunk
    FRONTIER, FRAMES = scope.frontier, scope.frames
    # Native JSONL requires two complete nonempty LF-terminated records.
    require(type(raw) is bytes and len(raw) <= 32 * 1024**2, 'Reference output cap')
    lines = raw.split(b'\n')
    require(len(lines) == 3 and lines[-1] == b'' and all(lines[:2]), 'Two complete reference records required')
    admitted, report = map(parse, lines[:2])
    fields(admitted, ADMITTED_KEYS, 'reference admitted')
    fields(report, REPORT_KEYS, 'reference report')
    shared = dict(requestID=context['request_id'].upper(), requestFingerprint=context['fingerprint'],
        profile=profile(scope), promptFileSHA256=context['prompt_sha'],
        promptTokenIDsSHA256=context['prompt_tokens_sha'], requestedOutputCount=OUTPUT,
        maximumTokens=PROMPT + OUTPUT, stopTokenIDs=[])
    exact(admitted, dict(kind='qwen_full_generation_reference_admitted', schemaVersion=1,
        **shared, manifestSHA256=MANIFEST, artifactSHA256=ARTIFACT, configurationSHA256=CONFIG,
        planSHA256=PLAN, verifiedModelLoaded=False, freshRequestStateCreated=False,
        correctnessOnly=True, throughputMeasurementValid=False), 'reference admitted')
    for key, value in dict(kind='qwen_full_generation_reference_report', schemaVersion=1,
        completed=True, modelReleased=True, allRequestStateRetired=True, verifiedFullModelLoads=1,
        freshFullModelRequests=1, correctnessOnly=True, throughputMeasurementValid=False,
        physicalTransferQualified=False, candidateNumericalComparisonPerformed=False).items():
        exact(report[key], value, 'reference report.' + key)
    # These envelopes are retained by the input pin but are not native/resource attestation here.
    require(type(report['resources']) is dict and type(report['runtime']) is dict
            and type(report['memory']) is list, 'Reference operational envelopes missing')
    execution = fields(report['execution'], EXECUTION_KEYS, 'reference execution')
    for key, value in dict(**shared, schema='qwen_full_generation_reference_v1', promptCount=PROMPT,
        chunkSize=CHUNK, finishReason='length', completedFrames=FRAMES, committedTokens=FRONTIER,
        finalStateCaptures=1, allRequestStateRetired=True, modelRemainsResident=True,
        fullVocabularyValuesRetainedForEveryToken=False, mtpEnabled=False, correctnessOnly=True,
        candidateNumericalComparisonPerformed=False, physicalTransferQualified=False).items():
        exact(execution[key], value, 'reference execution.' + key)
    exact(execution['source'], dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIG,
        sourceParameterLayoutSHA256=LAYOUT, planSHA256=PLAN, arithmeticEnvironmentSHA256=ARITHMETIC,
        bf16ConversionEnabled=True, embeddingActivationDType='bfloat16', sourceModelTensorBytes=model['source_bytes'],
        layerCount=model['layers'], vocabularySize=VOCAB), 'reference source')
    exact(execution['sourceLoad'], dict(schemaVersion=1, verifiedAggregateSHA256=ARTIFACT,
        configurationSHA256=CONFIG, parameterLayoutSHA256=LAYOUT, bf16ConversionEnabled=True,
        sourceModelTensorBytes=model['source_bytes'], loadedTensorBytes=model['source_bytes'],
        largestHostTensorBytes=model['largest'], sourceTensorCount=model['source_count'], tensorCount=model['source_count']), 'reference source load')
    require(type(execution['requirements']) is dict, 'Reference requirements missing')
    selected = token_ids(execution['selectedTokenIDs'], OUTPUT)
    exact(execution['selectedTokenIDsSHA256'], token_hash(selected), 'selected token hash')
    tokens = execution['tokens']
    require(type(tokens) is list and len(tokens) == OUTPUT, 'All reference token observations required')
    for ordinal, item in enumerate(tokens):
        fields(item, TOKEN_KEYS, 'reference token')
        for key, value in dict(outputOrdinal=ordinal, frame=selected_frame(ordinal, scope),
            committedTokens=PROMPT + ordinal, tokenID=selected[ordinal], logitsShape=[1, VOCAB],
            logitsDType='bfloat16', logitsByteCount=VOCAB * 2,
            policy='mlx_argmax_all_axes_with_finite_guard_v1',
            cpuCrosscheckPolicy='finite_maximum_lowest_vocabulary_index_v1',
            nativeSelectionMatchesCapturedFullRow=True).items():
            exact(item[key], value, 'reference token.' + key)
        integer(item['maximumTieCount'], 1, VOCAB)
        sha(item['logitsLogicalBytesSHA256'])
        value = item['maximumLogit']
        require(type(value) in (int, float) and math.isfinite(value), 'Reference maximum is not finite')
        try:
            packed = struct.pack('<f', value)
        except (OverflowError, struct.error):
            raise ValueError('Reference maximum exceeds Float32')
        require(struct.unpack('<I', packed)[0] & 65535 == 0
                and math.isfinite(struct.unpack('<f', packed)[0]), 'Reference maximum is not native BF16')
    row = execution['finalLogits']
    final_bytes = logical_bytes(row, VOCAB, 'bfloat16')
    maximum = max(row['values'])
    first = row['values'].index(maximum)
    tie_count = row['values'].count(maximum)
    exact(first, selected[-1], 'reference final CPU argmax')
    require(tokens[-1]['maximumLogit'] == maximum, 'Final reference maximum differs from full row')
    exact(tokens[-1]['maximumTieCount'], tie_count, 'final reference tie count')
    exact(tokens[-1]['logitsLogicalBytesSHA256'], row['logicalBytesSHA256'], 'final compact/full row join')
    entries = check_state(execution['finalState'], scope)
    check_timing(execution['timing'])
    return dict(execution=execution, selected=selected, final_bytes=final_bytes, entries=entries)


def check_timing(value):
    fields(value, 'clock requestStartNanoseconds firstSelectedTokenNanoseconds finalSelectedTokenNanoseconds '
        'retiredNanoseconds includesLoading includesSourceAndResourceAdmission '
        'firstTokenIncludesFreshStateConstruction continuationIncludesPriorEvidenceCapture '
        'externalTTFTMeasured throughputMeasurementValid', 'reference timing')
    for key, expected in dict(clock='DispatchTime.uptimeNanoseconds.same_process', includesLoading=False,
        includesSourceAndResourceAdmission=False, firstTokenIncludesFreshStateConstruction=True,
        continuationIncludesPriorEvidenceCapture=True, externalTTFTMeasured=False,
        throughputMeasurementValid=False).items():
        exact(value[key], expected, 'reference timing.' + key)
    times = [integer(value[key], 0, 2**64 - 1) for key in ('requestStartNanoseconds',
        'firstSelectedTokenNanoseconds', 'finalSelectedTokenNanoseconds', 'retiredNanoseconds')]
    require(times[0] <= times[1] <= times[2] <= times[3] and times[0] < times[3], 'Reference clock order differs')
