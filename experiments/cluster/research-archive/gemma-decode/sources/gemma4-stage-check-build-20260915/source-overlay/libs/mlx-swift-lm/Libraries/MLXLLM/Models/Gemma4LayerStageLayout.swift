import MLXLMCommon

public enum Gemma4LayerStageError: Error {
    case unsupportedConfiguration
    case invalidPartition
    case invalidInput
    case invalidCache
    case invalidNativeKV
    case wrongResponsibility
}

/// Native construction geometry, not an artifact/Plan identity or readiness
/// receipt. The authenticated Runtime Plan remains the source of those pins.
public struct Gemma4LayerStageLayout: Sendable {
    public let rank: Int
    public let sourceLayerRange: Range<Int>
    public let layerKinds: [CBv2LayerKind]
    public var globalLayerIndices: [Int] { Array(sourceLayerRange) }
    public var ownsFinalOutput: Bool { rank == 1 }

    public init(
        originalConfiguration: Gemma4Configuration,
        rank: Int, sourceLayerRange: Range<Int>
    ) throws {
        let config = originalConfiguration.textConfig
        guard originalConfiguration.modelType == "gemma4",
            gemma4SupportsProductionExpertTopology(config),
            gemma4SupportsSafeExpertQMMQuantization(config),
            config.vocabSize == 262_144, config.intermediateSize == 2_112,
            config.numAttentionHeads == 16, config.numKeyValueHeads == 8,
            config.numGlobalKeyValueHeads == 2, config.headDim == 256,
            config.globalHeadDim == 512, config.slidingWindow == 1_024,
            config.hiddenSizePerLayerInput == 0, config.numKvSharedLayers == 0,
            !config.useDoubleWideMlp, gemma4StageHasOriginalQuantization(config),
            config.tieWordEmbeddings, config.attentionKeqV,
            config.finalLogitSoftcapping == 30, config.rmsNormEps == 1e-6,
            config.slidingRopeTheta == 10_000, config.fullRopeTheta == 1_000_000,
            config.fullPartialRotaryFactor == 0.25,
            config.layerTypes == (0..<30).map({
                ($0 + 1).isMultiple(of: 6) ? "full_attention" : "sliding_attention"
            })
        else { throw Gemma4LayerStageError.unsupportedConfiguration }
        guard !sourceLayerRange.isEmpty,
            sourceLayerRange.lowerBound >= 0, sourceLayerRange.upperBound <= 30,
            (rank == 0 && sourceLayerRange.lowerBound == 0 && sourceLayerRange.upperBound < 30)
                || (rank == 1 && sourceLayerRange.lowerBound > 0 && sourceLayerRange.upperBound == 30)
        else { throw Gemma4LayerStageError.invalidPartition }
        self.rank = rank
        self.sourceLayerRange = sourceLayerRange
        let kinds = config.cbv2LayerKinds
        self.layerKinds = sourceLayerRange.enumerated().map { local, global in
            var kind = kinds[global]
            kind.modelLayerIndex = local
            return kind
        }
    }
}

/// Validate the original policy without relocating it or modifying the
/// topology classifier. The Runtime descriptor owns local-path relocation.
private func gemma4StageHasOriginalQuantization(_ config: Gemma4TextConfiguration) -> Bool {
    guard let policy = config.perLayerQuantization else { return false }
    let suffixes = ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"]
    let expected = Set((0..<30).flatMap { index in
        suffixes.map { "language_model.model.layers.\(index).\($0)" }
    })
    guard Set(policy.perLayerQuantization.keys) == expected else { return false }
    return expected.allSatisfy { path in
        guard case .quantize(let value)? = policy.perLayerQuantization[path] else { return false }
        return value.bits == 8 && value.groupSize == 64 && value.mode == .affine
    }
}
