"""Prospective lookahead two-rank comparison; never infers missing intermediate values."""
from audit_common import (ARTIFACT, CONFIG, CONSTRUCTIONS, STAGES, PLAN, RANGES,
    VOCAB, OUTPUT, FRONTIER, FRAMES, fields, exact, integer, sha, profile,
    agreement, token_hash, token_ids, selected_frame)
from audit_state import check_entries, state_fingerprint
from audit_scope import LEGACY, scope_for
from recorded_math import digest, logical_bytes, require

EVIDENCE_KEYS = ('schema execution agreement requestFingerprint profileFingerprint rank sourceLayerStart '
    'sourceLayerEnd finalFrame stateEntries logicalStateBytes stageStateSHA256 captureBudget '
    'resourceObservationCount minimumObservedActualFreeBytes minimumObservedAllocatorLimitBytes '
    'actualAllocatorBoundsUsed correctnessOnly throughputMeasurementValid stateBytesIncluded '
    'intermediateLogitRowsCompared independentNumericalComparisonPerformed physicalTransferQualified')
EXECUTION_KEYS = ('schema agreementFingerprint membershipEpoch identity selectedTokenIDs tokenChainSHA256 '
    'completedFrames committedTokens finishReason bothRequestStatesRetired modelRemainsResident mtpEnabled '
    'physicalTransferQualified independentNumericalComparisonPerformed externalTTFTMeasured prefillSchedule')


def compare(reference, candidates, expected_agreement, context):
    scope = scope_for(context)
    model = scope.model
    ARTIFACT, CONFIG = model['artifact'], model['configuration']
    CONSTRUCTIONS, STAGES, PLAN = scope.plan['constructions'], scope.plan['stages'], scope.plan['fingerprint']
    RANGES, VOCAB, OUTPUT, FRONTIER, FRAMES = scope.ranges, model['vocab'], scope.output, scope.frontier, scope.frames
    expected_hash = agreement(expected_agreement, context)
    require(type(candidates) is list and len(candidates) == 2, 'Exactly two ranked sidecars required')
    for rank, evidence in enumerate(candidates):
        fields(evidence, EVIDENCE_KEYS + (' finalLogits' if rank == 1 else ''), 'candidate evidence')
        for key, value in dict(schema='qwen_stage_generation_final_diagnostic_v1',
            agreement=expected_agreement, requestFingerprint=context['fingerprint'],
            profileFingerprint=profile(scope)['fingerprint'], rank=rank,
            sourceLayerStart=RANGES[rank][0], sourceLayerEnd=RANGES[rank][1],
            finalFrame=selected_frame(OUTPUT - 1, scope), actualAllocatorBoundsUsed=True,
            correctnessOnly=True, throughputMeasurementValid=False, stateBytesIncluded=False,
            intermediateLogitRowsCompared=False, independentNumericalComparisonPerformed=False,
            physicalTransferQualified=False).items():
            exact(evidence[key], value, 'candidate evidence.' + key)
        execution = fields(evidence['execution'], EXECUTION_KEYS, 'candidate execution')
        identity = dict(stageIndex=rank, requestFingerprint=context['fingerprint'],
            artifactAggregateSHA256=ARTIFACT, storageCommitmentSHA256=expected_agreement['storageCommitmentSHA256'],
            bf16ConversionEnabled=True, sourceConfigurationSHA256=CONFIG,
            constructionConfigurationSHA256=CONSTRUCTIONS[rank], planFingerprint=PLAN,
            stageFingerprint=STAGES[rank], activationDType='bfloat16')
        for key, value in dict(schema='qwen_stage_generation_result_v1', agreementFingerprint=expected_hash,
            membershipEpoch=expected_agreement['membershipEpoch'], identity=identity,
            selectedTokenIDs=reference['selected'], completedFrames=FRAMES, committedTokens=FRONTIER,
            finishReason='length', bothRequestStatesRetired=True, modelRemainsResident=True,
            mtpEnabled=False, physicalTransferQualified=False,
            independentNumericalComparisonPerformed=False, externalTTFTMeasured=False,
            prefillSchedule=dict(policy='oneChunkLookahead', rank=rank,
                preparedAheadFrames=scope.prefill_frames - 1 if rank == 0 else 0,
                maximumPreparedBoundaries=1 if rank == 0 and scope.prefill_frames > 1 else 0,
                pendingConsumedAtCompletion=0, decodePrefetchCount=0)).items():
            exact(execution[key], value, 'candidate execution.' + key)
        sha(execution['tokenChainSHA256'])
        initial_chain = digest(('qwen-generation-history-v1|' + expected_hash + '|'
                                + context['prompt_tokens_sha']).encode())
        require(execution['tokenChainSHA256'] != initial_chain, 'Token chain did not advance')
        size, pin = check_entries(evidence['stateEntries'], *RANGES[rank], scope=scope)
        exact(evidence['logicalStateBytes'], size, 'stage logical state bytes')
        exact(evidence['stageStateSHA256'], pin, 'stage state fingerprint')
        expected_entries = [e for e in reference['entries'] if RANGES[rank][0]
                            <= e['globalLayerIndex'] < RANGES[rank][1]]
        exact(evidence['stateEntries'], expected_entries, 'stage state metadata/digest comparison')
        check_capture_budget(evidence['captureBudget'], rank, scope)
        integer(evidence['resourceObservationCount'], 1)
        integer(evidence['minimumObservedActualFreeBytes'], 6 * 1024**3)
        integer(evidence['minimumObservedAllocatorLimitBytes'], 1)
    exact(candidates[0]['execution']['tokenChainSHA256'], candidates[1]['execution']['tokenChainSHA256'],
          'both ranks token-chain digest')
    candidate_row = candidates[1]['finalLogits']
    candidate_bytes = logical_bytes(candidate_row, VOCAB, 'bfloat16')
    require(candidate_bytes == reference['final_bytes'], 'Final reconstructed native BF16 row differs')
    # Exact bytes include signed zero; selection uses the native finite max/first-index policy.
    maximum = max(candidate_row['values'])
    exact(candidate_row['values'].index(maximum), reference['selected'][-1], 'candidate final CPU argmax')
    merged = candidates[0]['stateEntries'] + candidates[1]['stateEntries']
    exact(merged, reference['entries'], 'complete ordered state union')
    exact(state_fingerprint(merged, scope), reference['execution']['finalState']['fingerprint'], 'merged full-state fingerprint')
    return dict(schema='private_generation128_numerical_comparison_v1', status='passed',
        modelID=scope.model_id, stageCut=scope.cut, requestID=context['request_id'],
        requestFingerprint=context['fingerprint'], agreementFingerprint=expected_hash,
        membershipEpoch=expected_agreement['membershipEpoch'], expectedAgreement=expected_agreement,
        comparedSelectedTokenCount=OUTPUT, selectedTokenIDsSHA256=token_hash(reference['selected']),
        finalCompletedFrames=FRAMES, finalCommittedTokens=FRONTIER,
        tokenChainSHA256=candidates[0]['execution']['tokenChainSHA256'],
        tokenChainCrossRankEqualityChecked=True, tokenChainIndependentlyReconstructed=False,
        referenceCompactTokenMetadataChecked=OUTPUT, referenceIntermediateLogitHashesReconstructed=False,
        perTokenLogitComparisonPerformed=False, candidateIntermediateFrontiersIndependentlyVerified=False,
        finalNativeBF16RowReconstructed=True, finalNativeBF16RowBytesCompared=VOCAB * 2,
        finalLogitsLogicalBytesSHA256=candidate_row['logicalBytesSHA256'],
        finalCPUArgmaxTokenID=reference['selected'][-1], finalCPUArgmaxTieCount=candidate_row['values'].count(maximum),
        orderedStateEntriesCompared=len(merged), stageStateEntryCounts=[len(c['stateEntries']) for c in candidates],
        logicalStateBytes=reference['execution']['finalState']['logicalByteCount'],
        mergedStateFingerprint=state_fingerprint(merged, scope), positionOffsetEntriesReconstructed=model['layers'] // model['interval'],
        otherStateEntryDigestsCompared=len(merged) - model['layers'] // model['interval'], otherStateEntryBytesReconstructed=False,
        storageCommitmentComparedAsOpaqueIdentity=True, storageCommitmentIndependentlyRecomputed=False,
        expectedProvenanceIsCallerSupplied=True, nativeExecutionBindingVerified=False,
        declaredBuildAndPolicyIdentitiesIndependentlyAttested=False,
        loadedWeightValuesIndependentlyVerified=False, runtimeResourcePolicyReplayed=False,
        requestRetirementIndependentlyObserved=False, physicalTransferQualified=False,
        performanceQualification=False, throughputMeasurementValid=False, externalTTFTMeasured=False,
        scope='CPU comparison of pinned exported values and reported state digests; no physical/runtime attestation')


def check_capture_budget(value, rank, scope=LEGACY):
    VOCAB = scope.model['vocab']
    fields(value, 'rank vocabularySize activationDType logicalRowBytes float32RowBytes extraHostBytes '
        'extraNativeBytes originalRequestReservedBytes', 'capture budget')
    row, floating = (0, 0) if rank == 0 else (VOCAB * 2, VOCAB * 4)
    for key, expected in dict(rank=rank, vocabularySize=VOCAB, activationDType='bfloat16',
        logicalRowBytes=row, float32RowBytes=floating, extraHostBytes=row + floating).items():
        exact(value[key], expected, 'capture budget.' + key)
    integer(value['originalRequestReservedBytes'], 1)
    integer(value['extraNativeBytes'], row + floating)
    if rank == 0:
        exact(value['extraNativeBytes'], 0, 'rank0 capture allocation')
