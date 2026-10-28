"""Invented CPU evidence, not a native candidate or measured result."""
import copy
import struct
from audit_common import (ARTIFACT, CONFIG, MANIFEST, LAYOUT, PLAN, ARITHMETIC,
    STAGES, CONSTRUCTIONS, REQUEST_ID, profile, request_context, token_hash, agreement)
from audit_state import state_geometry, state_fingerprint
from recorded_math import canonical, digest
from audit_scope import LEGACY
from audit_common import selected_frame


def fixture(scope=None, request_id=None):
    chosen = LEGACY if scope is None else scope
    model = chosen.model
    ARTIFACT, CONFIG, MANIFEST, LAYOUT, PLAN = (model['artifact'], model['configuration'],
        model['manifest'], model['layout'], chosen.plan['fingerprint'])
    STAGES, CONSTRUCTIONS = chosen.plan['stages'], chosen.plan['constructions']
    PROMPT, CHUNK, OUTPUT, FRONTIER, FRAMES = chosen.prompt, chosen.chunk, chosen.output, chosen.frontier, chosen.frames
    request_id = REQUEST_ID if request_id is None else request_id
    prompt_raw = canonical([7] * PROMPT) + b'\n'
    context = request_context(prompt_raw, request_id, scope)
    selected = [3 * (i + 1) for i in range(OUTPUT)]
    values = [-2.0] * 248320
    values[1], values[2] = -0.0, 0.0
    values[selected[-1]], values[400] = 8.0, 8.0
    row_bytes = b''.join(struct.pack('<H', struct.unpack('<I', struct.pack('<f', v))[0] >> 16) for v in values)
    row = dict(shape=[1, 248320], dtype='bfloat16', byteCount=496640,
               logicalBytesSHA256=digest(row_bytes), values=values)
    entries = state_geometry(scope=chosen)
    for e in entries:
        e['sha256'] = (digest(struct.pack('<i', FRONTIER)) if e['component'] == 'kv.position_offsets'
                       else digest(('invented-state-' + str(e['globalLayerIndex']) + '-' + e['component']).encode()))
    state = dict(committedTokens=FRONTIER, entries=entries, logicalByteCount=sum(e['byteCount'] for e in entries),
                 fingerprint=state_fingerprint(entries, chosen))
    tokens = []
    for i in range(OUTPUT):
        frame = selected_frame(i, chosen)
        tokens.append(dict(outputOrdinal=i, frame=frame, committedTokens=PROMPT+i, tokenID=selected[i],
            maximumTieCount=2 if i == OUTPUT - 1 else 1, maximumLogit=8.0 if i == OUTPUT - 1 else 2.0,
            logitsShape=[1, 248320], logitsDType='bfloat16', logitsByteCount=496640,
            logitsLogicalBytesSHA256=row['logicalBytesSHA256'] if i == OUTPUT - 1 else digest(('invented-row-' + str(i)).encode()),
            policy='mlx_argmax_all_axes_with_finite_guard_v1',
            cpuCrosscheckPolicy='finite_maximum_lowest_vocabulary_index_v1', nativeSelectionMatchesCapturedFullRow=True))
    shared = dict(requestID=request_id.upper(), requestFingerprint=context['fingerprint'], profile=profile(chosen),
        promptFileSHA256=context['prompt_sha'], promptTokenIDsSHA256=context['prompt_tokens_sha'],
        requestedOutputCount=OUTPUT, maximumTokens=PROMPT+OUTPUT, stopTokenIDs=[])
    admitted = dict(kind='qwen_full_generation_reference_admitted', schemaVersion=1, **shared,
        manifestSHA256=MANIFEST, artifactSHA256=ARTIFACT, configurationSHA256=CONFIG, planSHA256=PLAN,
        verifiedModelLoaded=False, freshRequestStateCreated=False, correctnessOnly=True, throughputMeasurementValid=False)
    execution = dict(schema='qwen_full_generation_reference_v1', **shared,
        source=dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIG,
            sourceParameterLayoutSHA256=LAYOUT, planSHA256=PLAN, arithmeticEnvironmentSHA256=ARITHMETIC,
            bf16ConversionEnabled=True, embeddingActivationDType='bfloat16', sourceModelTensorBytes=model['source_bytes'],
            layerCount=model['layers'], vocabularySize=248320),
        sourceLoad=dict(schemaVersion=1, verifiedAggregateSHA256=ARTIFACT, configurationSHA256=CONFIG,
            parameterLayoutSHA256=LAYOUT, bf16ConversionEnabled=True, sourceModelTensorBytes=model['source_bytes'],
            loadedTensorBytes=model['source_bytes'], largestHostTensorBytes=model['largest'], sourceTensorCount=model['source_count'], tensorCount=model['source_count']),
        promptCount=PROMPT, chunkSize=CHUNK, requirements={}, selectedTokenIDs=selected,
        selectedTokenIDsSHA256=token_hash(selected), finishReason='length', completedFrames=FRAMES, committedTokens=FRONTIER,
        tokens=tokens, finalLogits=row, finalState=state,
        timing=dict(clock='DispatchTime.uptimeNanoseconds.same_process', requestStartNanoseconds=1,
            firstSelectedTokenNanoseconds=2, finalSelectedTokenNanoseconds=3, retiredNanoseconds=4,
            includesLoading=False, includesSourceAndResourceAdmission=False,
            firstTokenIncludesFreshStateConstruction=True, continuationIncludesPriorEvidenceCapture=True,
            externalTTFTMeasured=False, throughputMeasurementValid=False),
        finalStateCaptures=1, allRequestStateRetired=True, modelRemainsResident=True,
        fullVocabularyValuesRetainedForEveryToken=False, mtpEnabled=False, correctnessOnly=True,
        candidateNumericalComparisonPerformed=False, physicalTransferQualified=False)
    report = dict(kind='qwen_full_generation_reference_report', schemaVersion=1, completed=True,
        modelReleased=True, allRequestStateRetired=True, verifiedFullModelLoads=1, freshFullModelRequests=1,
        correctnessOnly=True, throughputMeasurementValid=False, physicalTransferQualified=False,
        candidateNumericalComparisonPerformed=False, execution=execution, resources={}, runtime={}, memory=[])
    expected = dict(schema='qwen_stage_generation_agreement_v1', rankCount=2,
        membershipEpoch='11111111-2222-4333-8444-555555555555', requestID=request_id,
        requestFingerprint=context['fingerprint'], profileFingerprint=profile(chosen)['fingerprint'],
        sourceConfigurationSHA256=CONFIG, artifactAggregateSHA256=ARTIFACT,
        storageCommitmentSHA256='a' * 64, planFingerprint=PLAN, stageFingerprints=list(STAGES),
        rankBuildSHA256=['b' * 64, 'c' * 64], numericalPolicySHA256='d' * 64, mtpEnabled=False)
    candidates = []
    for rank, (start, end) in enumerate(chosen.ranges):
        local_entries = copy.deepcopy([e for e in entries if start <= e['globalLayerIndex'] < end])
        identity = dict(stageIndex=rank, requestFingerprint=context['fingerprint'], artifactAggregateSHA256=ARTIFACT,
            storageCommitmentSHA256=expected['storageCommitmentSHA256'], bf16ConversionEnabled=True,
            sourceConfigurationSHA256=CONFIG, constructionConfigurationSHA256=CONSTRUCTIONS[rank],
            planFingerprint=PLAN, stageFingerprint=STAGES[rank], activationDType='bfloat16')
        candidate = dict(schema='qwen_stage_generation_final_diagnostic_v1',
            execution=dict(schema='qwen_stage_generation_result_v1', agreementFingerprint=agreement(expected, context),
                membershipEpoch=expected['membershipEpoch'], identity=identity,
                selectedTokenIDs=list(selected), tokenChainSHA256='e' * 64, completedFrames=FRAMES, committedTokens=FRONTIER,
                finishReason='length', bothRequestStatesRetired=True, modelRemainsResident=True, mtpEnabled=False,
                physicalTransferQualified=False, independentNumericalComparisonPerformed=False, externalTTFTMeasured=False),
            agreement=copy.deepcopy(expected), requestFingerprint=context['fingerprint'],
            profileFingerprint=profile(chosen)['fingerprint'], rank=rank, sourceLayerStart=start, sourceLayerEnd=end,
            finalFrame=copy.deepcopy(tokens[-1]['frame']), stateEntries=local_entries,
            logicalStateBytes=sum(e['byteCount'] for e in local_entries), stageStateSHA256=state_fingerprint(local_entries, chosen),
            captureBudget=dict(rank=rank, vocabularySize=248320, activationDType='bfloat16',
                logicalRowBytes=496640*rank, float32RowBytes=993280*rank, extraHostBytes=1489920*rank,
                extraNativeBytes=1507328*rank, originalRequestReservedBytes=800000000),
            resourceObservationCount=1, minimumObservedActualFreeBytes=6*1024**3,
            minimumObservedAllocatorLimitBytes=2**34, actualAllocatorBoundsUsed=True, correctnessOnly=True,
            throughputMeasurementValid=False, stateBytesIncluded=False, intermediateLogitRowsCompared=False,
            independentNumericalComparisonPerformed=False, physicalTransferQualified=False)
        if rank == 1:
            candidate['finalLogits'] = copy.deepcopy(row)
        candidates.append(candidate)
    return prompt_raw, context, admitted, report, expected, candidates


def reference_bytes(admitted, report):
    return canonical(admitted) + b'\n' + canonical(report) + b'\n'
