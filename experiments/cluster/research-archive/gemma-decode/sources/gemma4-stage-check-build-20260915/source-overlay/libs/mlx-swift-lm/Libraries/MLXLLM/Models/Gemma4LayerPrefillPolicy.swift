import MLXLMCommon

/// One policy for ordinary and ranged trunks. Global layer identity is
/// independent of a stage's local module/cache index.
struct Gemma4LayerPrefillPolicy {
    let outputTailRows: Int?
    let useLastQuery: Bool
    let expertPrefill: Bool
    let submitIntermediate: Bool
}

func gemma4LayerPrefillPolicy(
    _ config: Gemma4TextConfiguration,
    globalLayerIndex: Int,
    finalOutputLayerIndex: Int,
    ownsFinalOutput: Bool,
    schedulePrefill: Bool,
    isCBv2: Bool,
    batchSize: Int,
    sequenceLength: Int,
    inputSequenceLength: Int,
    hasLastQueryCache: Bool,
    tailRows: Int = gemma4PrefillTailRows,
    minimumTailChunk: Int = gemma4PrefillTailMinChunk,
    submissionInterval: Int = gemma4PrefillChunkEvalLayers,
    lastQueryEnabled: Bool = gemma4PrefillLastQueryEnabled
) -> Gemma4LayerPrefillPolicy {
    let isFinalPromptLayer = schedulePrefill && isCBv2 && ownsFinalOutput
        && globalLayerIndex == finalOutputLayerIndex
        && batchSize > 0 && sequenceLength >= minimumTailChunk
    let outputTailRows: Int? = isFinalPromptLayer && tailRows > 0
        ? min(tailRows, sequenceLength) : nil
    return Gemma4LayerPrefillPolicy(
        outputTailRows: outputTailRows,
        useLastQuery: gemma4UseLastQueryPrefill(
            config, layerIdx: globalLayerIndex, batchSize: batchSize,
            sequenceLength: sequenceLength, outputTailRows: outputTailRows,
            hasCapableCache: hasLastQueryCache, enabled: lastQueryEnabled),
        expertPrefill: gemma4AllowsWeightedExpertUnsort(schedulePrefill: schedulePrefill),
        submitIntermediate: gemma4ShouldSubmitPrefillChunkEval(
            schedulePrefill: schedulePrefill, isCBv2: isCBv2,
            inputLength: inputSequenceLength, layerNumber: globalLayerIndex + 1,
            interval: submissionInterval))
}
