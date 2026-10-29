"""Invented CPU records for prospective rejection tests; never native evidence."""
import copy
import struct
from tiny12_expected import FRONTIERS, canonical, expected, sha
from tiny12_recorded import state_geometry


def frame_records(source, request):
    originals, candidates, identities = [], [], []
    for index, frontier in enumerate(FRONTIERS):
        frame = request['steps'][index]['frame']
        entries = [dict(item, sha256=sha(('invented-state-%d-%d-%s' %
            (frontier, item['globalLayerIndex'], item['component'])).encode()))
            for item in state_geometry(12, 'bfloat16', frontier, None)]
        state_identity = ['%s|%s|%s|%s|%s|%s' % (e['globalLayerIndex'], e['component'], e['shape'],
            e['dtype'], e['byteCount'], e['sha256']) for e in entries]
        state = dict(committedTokens=frontier, entries=entries, logicalByteCount=sum(e['byteCount'] for e in entries),
            fingerprint=sha(('cbv2-owned-state-v1\ntokens=%d\n' % frontier + '\n'.join(state_identity)).encode()))
        row = None
        if index >= 2:
            values = [float(i % 32) / 16 for i in range(512)]
            values[0] = -0.0; values[17] = float(index + 8)
            raw = b''.join(struct.pack('<f', value)[2:] for value in values)
            row = dict(shape=[1, 512], dtype='bfloat16', byteCount=1024, logicalBytesSHA256=sha(raw), values=values)
        original = dict(frame=frame, committedTokens=frontier, outputKind='logits' if row else 'evaluation_handle',
            outputShape=[1, 512] if row else [1, 1], outputDType='bfloat16', state=state)
        candidate = dict(frame=copy.deepcopy(frame), committedTokens=frontier, stateEntriesCompared=27,
            logicalStateBytesPerSide=state['logicalByteCount'], globalStateSHA256=state['fingerprint'],
            stateMetadataAndDigestsExact=True)
        if row:
            original['logits'] = row
            candidate.update(logits=copy.deepcopy(row), nativeLogitBytesExact=True)
        boolean = 'true' if frame['finalPromptChunk'] else 'false'
        identities.append(sha(('qwen-recorded-frame-v1\n%d|%s|%d|%d|%s\ntokens=%d\n%s|%s|bfloat16\n%s\n%s' %
            (index, frame['phase'], frame['tokenOffset'], frame['tokenCount'], boolean, frontier,
             original['outputKind'], original['outputShape'], state['fingerprint'],
             row['logicalBytesSHA256'] if row else 'no-logits')).encode()))
        originals.append(original); candidates.append(candidate)
    return originals, candidates, identities


def suffix():
    metadata = expected()
    source = {key: metadata[key] for key in ('sourceConfigurationSHA256', 'planSHA256',
        'sourceParameterLayoutSHA256', 'sourceModelTensorBytes')}
    source.update(artifactAggregateSHA256='a' * 64, bf16ConversionEnabled=True,
                  embeddingActivationDType='bfloat16', layerCount=12, vocabularySize=512)
    loads, summaries = [], []
    for index, stage in enumerate(metadata['stages']):
        receipt = {key: source[key] for key in ('sourceConfigurationSHA256', 'sourceParameterLayoutSHA256',
            'planSHA256', 'sourceModelTensorBytes', 'bf16ConversionEnabled', 'embeddingActivationDType')}
        receipt.update(schemaVersion=1, stageIndex=index, verifiedAggregateSHA256=source['artifactAggregateSHA256'],
                       sourceTensorManifestSHA256='b' * 64)
        for key in ('constructionConfigurationSHA256', 'stagePlanSHA256', 'parameterLayoutSHA256',
                    'activeParameterLayoutSHA256', 'activeMappingSHA256', 'loadedTensorBytes',
                    'largestHostTensorBytes', 'activeTensors', 'inertModules', 'inertTensorBytes'):
            receipt[key] = copy.deepcopy(stage[key])
        summary = {key: receipt[key] for key in ('stageIndex', 'constructionConfigurationSHA256', 'stagePlanSHA256',
            'activeMappingSHA256', 'activeParameterLayoutSHA256', 'parameterLayoutSHA256', 'loadedTensorBytes', 'inertTensorBytes')}
        summary.update(activeTensorCount=len(stage['activeTensors']), inertTensorCount=2 if index == 0 else 1)
        summaries.append(summary); loads.append(receipt)
    common = {key: loads[0][key] for key in ('verifiedAggregateSHA256', 'sourceConfigurationSHA256', 'planSHA256',
        'sourceTensorManifestSHA256', 'sourceModelTensorBytes', 'bf16ConversionEnabled')}
    common.update(schemaVersion=1, sourceTensorCount=352, canonicalTensorCount=352,
        largestSourceTensorBytes=max(x['byteCount'] for x in metadata['fullCanonicalTensors']), stages=summaries)
    for receipt in loads:
        receipt.update(storageCommitment=copy.deepcopy(common), storageCommitmentSHA256=sha(canonical(common)))
    identity = '00000000-0000-0000-0000-000000000012'
    spec = dict(requestID=identity.upper(), promptCount=65, chunkSize=32, outputCount=4)
    prompt, teacher = [3 + ((i * 17 + 7) % 509) for i in range(65)], [12, 25, 38]
    request_hash = sha(('qwen-stage-request-v1|%s|65|32|4' % identity).encode())
    recorded_hash = sha(('qwen-layer-stage-recorded-request-v1\n%s\nvocabulary=512\nprompt=%s\nteacher=%s' %
        (request_hash, ','.join(map(str, prompt)), ','.join(map(str, teacher)))).encode())
    steps = []
    for index, frontier in enumerate(FRONTIERS):
        offset = 0 if index == 0 else FRONTIERS[index - 1]
        frame = dict(sequence=index, phase='prefill' if index < 3 else 'decode', tokenOffset=offset,
                     tokenCount=frontier-offset, finalPromptChunk=index == 2)
        steps.append(dict(frame=frame, tokenIDs=prompt[offset:frontier] if index < 3 else [teacher[index-3]]))
    request = dict(request=spec, vocabularySize=512, promptTokenIDs=prompt, teacherTokenIDs=teacher,
                   fingerprint=recorded_hash, steps=steps)
    originals, candidates, frame_hashes = frame_records(source, request)
    baseline_hash = sha(('qwen-layer-stage-baseline-v1\n%s\n%s\n%s' %
        (recorded_hash, sha(canonical(source)), '\n'.join(frame_hashes))).encode())
    baseline = dict(kind='qwen_layer_stage_recorded_baseline', correctnessOnly=True, throughputMeasurementValid=False,
        request=request, source=source, frames=originals, fingerprint=baseline_hash, allRequestStateRetired=True)
    comparison = dict(kind='qwen_layer_stage_recorded_comparison', correctnessOnly=True, throughputMeasurementValid=False,
        sequentialOneProcessOnly=True, nativeBoundaryBytesCopied=True, baselineEvidenceSHA256=baseline_hash,
        requestSHA256=recorded_hash, source=copy.deepcopy(source), stageStorageCommitmentSHA256=loads[0]['storageCommitmentSHA256'],
        frames=candidates, allRequestStateRetired=True)
    phases = ['before_baseline_load', 'baseline_released_cache_cleared', 'both_stages_loaded',
        'stage_requests_retired', 'stage_models_released_cache_cleared']
    memory = [dict(phase=phase, activeMLXBytes=128, cachedMLXBytes=0, peakMLXBytesSinceProcessStart=1024) for phase in phases]
    conv, ssm, kv = 4*3*768, 4*2*128*128, 2*4*69*2*64
    budget = 3*9*(conv+ssm) + 3*(kv+4) + max(conv, ssm, kv//2) + 2*32*128*4
    report = dict(kind='qwen_layer_stage_comparison_report', correctnessOnly=True, throughputMeasurementValid=False,
        baselineModelReleasedBeforeStageLoading=True, stageModelsReleasedAfterComparison=True,
        conservativeStateAndBoundaryBytes=budget, stageLoads=loads, comparison=comparison, memory=memory)
    checkpoint = dict(kind='qwen_layer_stage_baseline_checkpoint', baselineModelReleasedBeforeStageLoading=True,
        baseline=baseline, memory=copy.deepcopy(memory[:2]))
    wrapper = dict(kind='qwen_layer_stage_unequal_cut_recording_check', fixtureProfile='tiny-layer-stage-12x4',
        selectedCut=4, layerCounts=[4, 8], correctnessOnly=True, throughputMeasurementValid=False, comparison=report)
    return checkpoint, wrapper


def legacy_prefix():
    """Minimum invented values accepted by the unchanged legacy eleven contract."""
    result = []
    for dtype, wrapped, fp16 in [('float32', False, False), ('bfloat16', True, False), ('bfloat16', True, True)]:
        receipts = [dict(activeTensors=[{}] * count, storageCommitmentSHA256='a' * 64,
            verifiedAggregateSHA256='b' * 64, sourceConfigurationSHA256='c' * 64, planSHA256='d' * 64)
            for count in (118, 119)]
        loader = dict(kind='qwen_layer_stage_loader_check', syntheticDType=dtype, wrapped=wrapped,
            fp16LayerMetadata=fp16, tensorChecks=237, tensorChecksAfterSourceDeletion=237,
            fp16MetadataTensorCount=124 if fp16 else 0, sourceTensorBytes=237, activeTensorBytes=[118,119],
            receipts=receipts, badAggregateRejectedStages=[0,1], corruptedSourceRejectedStages=[0,1], modelForwardCompared=False)
        for key in ('allActiveShapesDTypesAndBytesMatchOrdinary', 'activeNamesAndBytesConserveCanonicalSource',
            'independentCompactZeroOffsetActiveBuffersBeforeForward', 'previouslyLoadedParameterHandlesUnchangedOnRejection',
            'inactiveParametersCheckedSeparately', 'sourceFilesCorruptedAndDeleted', 'loaderProofPrecedesAnyTransformerForward'):
            loader[key] = True
        frames = []
        for index, frontier in enumerate(FRONTIERS):
            entry = dict(committedTokens=frontier, phase='prefill' if index < 3 else 'decode',
                stateEntriesCompared=18, stateBytesCompared=1, stateShapesDTypesAndBytesExact=True)
            if index >= 2:
                entry.update(logitsBytesExact=True, logits=dict(shape=[1,512]))
            frames.append(entry)
        parity = dict(kind='qwen_layer_stage_parity_check', syntheticDType=dtype, wrapped=wrapped,
            fp16LayerMetadata=fp16, throughputMeasurementValid=False,
            promptTokenIDs=[3+((i*17+7)%509) for i in range(65)], teacherTokenIDs=[12,25,38], frames=frames,
            artifactAggregateSHA256='b'*64, sourceConfigurationSHA256='c'*64, planSHA256='d'*64)
        for key in ('correctnessOnly', 'missingResidualRejectedAndRetired', 'allRequestsRetired',
                    'sourceFilesDeletedBeforeForward', 'sequentialOneProcessOnly', 'nativeBoundaryBytesCopied'):
            parity[key] = True
        lifecycle = dict(kind='qwen_layer_stage_lifecycle_check', correctnessOnly=True, throughputMeasurementValid=False,
            failedStageFrontiers=[32,0], faultInjectedAfterFirstStageCommit=True, bothRequestsFailedAndRetired=True,
            retiredRequestReuseRejected=2, recoveryOnSameResidentModels=copy.deepcopy(parity))
        result.extend((loader, parity, lifecycle))
    checkpoint, wrapper = suffix()
    report = wrapper['comparison']
    checkpoint['baseline']['request']['request']['requestID'] = '00000000-0000-0000-0000-000000000008'
    checkpoint['baseline']['source']['layerCount'] = report['comparison']['source']['layerCount'] = 8
    for baseline, compared in zip(checkpoint['baseline']['frames'], report['comparison']['frames']):
        baseline['state']['entries'] = baseline['state']['entries'][:18]
        compared['stateEntriesCompared'] = 18
    result.extend((checkpoint, report))
    return result


def records():
    return legacy_prefix() + list(suffix())
