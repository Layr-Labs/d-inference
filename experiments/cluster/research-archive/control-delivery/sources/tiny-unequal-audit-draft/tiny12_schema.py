"""Closed DTO shape for the new two-record suffix only; legacy schema unchanged."""
from tiny12_expected import equal, require


def keys(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label + ' fields differ')


def frame(value):
    keys(value, 'sequence phase tokenOffset tokenCount finalPromptChunk', 'Frame')
    for field in ('sequence', 'tokenOffset', 'tokenCount'):
        require(type(value[field]) is int, 'Frame integer type differs')
    require(type(value['finalPromptChunk']) is bool, 'Frame final flag differs')


def closed_suffix(checkpoint, wrapper):
    keys(wrapper, 'kind fixtureProfile selectedCut layerCounts correctnessOnly throughputMeasurementValid comparison', 'Unequal wrapper')
    equal({k: v for k, v in wrapper.items() if k != 'comparison'},
        dict(kind='qwen_layer_stage_unequal_cut_recording_check', fixtureProfile='tiny-layer-stage-12x4',
             selectedCut=4, layerCounts=[4, 8], correctnessOnly=True, throughputMeasurementValid=False),
        'Unequal wrapper scope/selection differs')
    keys(checkpoint, 'kind baselineModelReleasedBeforeStageLoading baseline memory', 'Trailing checkpoint')
    report = wrapper['comparison']
    keys(report, 'kind correctnessOnly throughputMeasurementValid baselineModelReleasedBeforeStageLoading stageModelsReleasedAfterComparison conservativeStateAndBoundaryBytes stageLoads comparison memory', 'Comparison report')
    baseline, compared = checkpoint['baseline'], report['comparison']
    keys(baseline, 'kind correctnessOnly throughputMeasurementValid request source frames fingerprint allRequestStateRetired', 'Baseline')
    keys(compared, 'kind correctnessOnly throughputMeasurementValid sequentialOneProcessOnly nativeBoundaryBytesCopied baselineEvidenceSHA256 requestSHA256 source stageStorageCommitmentSHA256 frames allRequestStateRetired', 'Recorded comparison')
    request = baseline['request']
    keys(request, 'request vocabularySize promptTokenIDs teacherTokenIDs fingerprint steps', 'Recorded request')
    keys(request['request'], 'requestID promptCount chunkSize outputCount', 'Request specification')
    require(type(request['steps']) is list and len(request['steps']) == 6, 'Six steps required')
    for step in request['steps']:
        keys(step, 'frame tokenIDs', 'Recorded step')
        frame(step['frame'])
    for collection in (baseline['frames'], compared['frames']):
        require(type(collection) is list and len(collection) == 6, 'Six frame records required')
    for index, (original, candidate) in enumerate(zip(baseline['frames'], compared['frames'])):
        optional = ' logits' if index >= 2 else ''
        keys(original, 'frame committedTokens outputKind outputShape outputDType state' + optional, 'Baseline frame')
        keys(candidate, 'frame committedTokens stateEntriesCompared logicalStateBytesPerSide globalStateSHA256 stateMetadataAndDigestsExact'
             + (' logits nativeLogitBytesExact' if index >= 2 else ''), 'Compared frame')
        frame(original['frame']); frame(candidate['frame'])
        keys(original['state'], 'committedTokens entries logicalByteCount fingerprint', 'State')
    require(type(report['stageLoads']) is list and len(report['stageLoads']) == 2, 'Two stage load receipts required')
    for receipt in report['stageLoads']:
        keys(receipt, 'schemaVersion stageIndex verifiedAggregateSHA256 sourceConfigurationSHA256 constructionConfigurationSHA256 planSHA256 stagePlanSHA256 sourceTensorManifestSHA256 sourceParameterLayoutSHA256 parameterLayoutSHA256 activeParameterLayoutSHA256 activeMappingSHA256 embeddingActivationDType bf16ConversionEnabled sourceModelTensorBytes loadedTensorBytes largestHostTensorBytes activeTensors inertModules inertTensorBytes storageCommitment storageCommitmentSHA256', 'Stage receipt')
        commitment = receipt['storageCommitment']
        keys(commitment, 'schemaVersion verifiedAggregateSHA256 sourceConfigurationSHA256 planSHA256 sourceTensorManifestSHA256 sourceModelTensorBytes largestSourceTensorBytes sourceTensorCount canonicalTensorCount bf16ConversionEnabled stages', 'Storage commitment')
        require(type(commitment['stages']) is list and len(commitment['stages']) == 2, 'Two storage summaries required')
        for stage in commitment['stages']:
            keys(stage, 'stageIndex constructionConfigurationSHA256 stagePlanSHA256 activeMappingSHA256 activeParameterLayoutSHA256 parameterLayoutSHA256 loadedTensorBytes activeTensorCount inertTensorBytes inertTensorCount', 'Storage summary')
    return report


def strict_scalar_types(value, path=()):
    # Native DTOs encode no Float outside the actual logit-values arrays. Their
    # representability/finite/signed-zero validation belongs to the frozen math.
    if path and path[-1] == 'values':
        return
    if type(value) is dict:
        for key, child in value.items():
            strict_scalar_types(child, path + (key,))
    elif type(value) is list:
        for child in value:
            strict_scalar_types(child, path)
    else:
        require(type(value) in (str, int, bool), 'Unexpected scalar/null outside native logits')
        if type(value) is bool:
            require(path and path[-1] in {'finalPromptChunk', 'correctnessOnly', 'throughputMeasurementValid',
                'baselineModelReleasedBeforeStageLoading', 'stageModelsReleasedAfterComparison',
                'allRequestStateRetired', 'sequentialOneProcessOnly', 'nativeBoundaryBytesCopied',
                'stateMetadataAndDigestsExact', 'nativeLogitBytesExact', 'bf16ConversionEnabled'},
                'Boolean substituted for a non-flag field')
        if type(value) is int:
            require(0 <= value <= 2**63 - 1, 'Integer outside native DTO range')
