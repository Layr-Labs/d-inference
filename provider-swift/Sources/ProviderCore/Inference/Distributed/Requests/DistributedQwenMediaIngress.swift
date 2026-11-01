import Foundation
import CryptoKit
import DarkbloomClusterProtocol
import MLX
import MLXLMCommon
import MLXVLM

/// Metadata and preprocessing for a pair that explicitly advertises the Qwen
/// media contract. This owns no language model or vision tower. The native
/// ranks reproduce the patches/positions and run their verified model weights.
public struct DistributedQwenMediaIngress: Sendable {
    let configuration: Qwen35Configuration
    let configurationBytes: Data
    let processorBytes: Data
    let artifactSHA256: String
    let configurationSHA256: String
    let processorSHA256: String
    let maximumPromptTokens: Int

    struct Source: Sendable {
        let kind: ClusterQwenMedia.Kind
        let bytes: Data
        let decodedPixels: Int
        /// The admitted preprocessing upper bound, before arrays are created.
        let maximumPatches: Int
    }
    struct Description: Sendable {
        let tokens: [Int]
        let wire: Data
        let mediaKind: EngineV2MediaKind
    }
    struct Prepared: Sendable {
        let tokens: [Int]
        let lifetime: DistributedQwenMediaLifetime
        let mediaKind: EngineV2MediaKind
    }

    init(configuration bytes: Data, processorConfiguration: Data,
        artifactSHA256: String, expectedConfigurationSHA256: String,
        maximumPromptTokens: Int
    ) throws {
        guard !bytes.isEmpty, bytes.count <= 1 << 20,
            !processorConfiguration.isEmpty, processorConfiguration.count <= 1 << 20,
            ClusterQwenMedia.sha256(bytes) == expectedConfigurationSHA256,
            artifactSHA256.count == 64,
            artifactSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            (1...ClusterWorkerLimits.wirePromptTokens).contains(maximumPromptTokens) else {
            throw DistributedEngineError.invalidConfiguration("Qwen media metadata identity or bounds differ")
        }
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: bytes)
        let processor = try Qwen3VLMediaProcessor(modelConfiguration: bytes,
            processorConfiguration: processorConfiguration)
        let vision = configuration.visionConfiguration
        guard ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35"].contains(configuration.modelType),
            processor.configuration.patchSize == 16, processor.configuration.mergeSize == 2,
            processor.configuration.temporalPatchSize == 2,
            vision.patchSize == 16, vision.spatialMergeSize == 2, vision.temporalPatchSize == 2,
            vision.inChannels == 3, vision.outHiddenSize == configuration.textConfiguration.hiddenSize,
            vision.hiddenSize > 0, vision.numHeads > 0,
            vision.hiddenSize.isMultiple(of: vision.numHeads),
            configuration.vocabSize > 0, configuration.vocabSize <= ClusterWorkerLimits.vocabularySize,
            Set([configuration.imageTokenIndex, configuration.videoTokenIndex,
                 configuration.visionStartTokenId, configuration.visionEndTokenId]).count == 4 else {
            throw DistributedEngineError.invalidConfiguration("Qwen media processor/model geometry differs")
        }
        self.configuration = configuration
        configurationBytes = bytes
        processorBytes = processorConfiguration
        self.artifactSHA256 = artifactSHA256
        configurationSHA256 = expectedConfigurationSHA256
        processorSHA256 = ClusterQwenMedia.sha256(processorConfiguration)
        self.maximumPromptTokens = maximumPromptTokens
    }

    /// Describe actual product output. Caller owns an admitted preprocessing
    /// scope until all input/position arrays and their host aliases are dropped.
    /// A shape or digest mismatch cannot reach native admission.
    func describe(_ input: LMInput, sources: [Source], mlxErrors: MLX.ErrorBox,
        towerLimits: VisionTowerBudget.Limits = VisionTowerBudget.liveLimits
    ) throws -> Description {
        let c = configuration
        guard [.int32, .int64].contains(input.text.tokens.dtype),
            input.text.tokens.ndim == 2, input.text.tokens.dim(0) == 1,
            (1...maximumPromptTokens).contains(input.text.tokens.dim(1)) else {
            throw EngineV2VisionPrefillError.unsupportedMedia("Qwen media requires one bounded prompt")
        }
        eval(input.text.tokens)
        try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
        let wideTokens = input.text.tokens.asType(.int64).asArray(Int64.self)
        try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
        guard wideTokens.allSatisfy({ $0 >= 0 && $0 < Int64(c.vocabSize) && Int32(exactly: $0) != nil }) else {
            throw EngineV2VisionPrefillError.unsupportedMedia("Qwen media token outside vocabulary")
        }
        let tokens = wideTokens.map(Int.init)
        if let mask = input.text.mask {
            eval(mask)
            try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
            guard [.bool, .int8, .int32].contains(mask.dtype), mask.shape == input.text.tokens.shape,
                mask.asType(.int32).asArray(Int32.self).allSatisfy({ $0 == 1 }) else {
                throw EngineV2VisionPrefillError.unsupportedMedia("Qwen media padding requires request validity support")
            }
        }
        let imageGrids = input.image?.frames ?? [], videoGrids = input.video?.frames ?? []
        func counts(_ grids: [THW]) throws -> [Int] {
            try grids.map { grid in
                guard grid.t > 0, grid.h > 0, grid.w > 0, grid.h.isMultiple(of: 2), grid.w.isMultiple(of: 2),
                    let rows = VisionTowerBudget.patchCount(grid), rows > 0, rows.isMultiple(of: 4),
                    rows / 4 < maximumPromptTokens else {
                    throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: 0)
                }
                return rows / 4
            }
        }
        let imageCounts = try counts(imageGrids), videoCounts = try counts(videoGrids)
        let spans = try EngineV2VisionPrefill.carveSpans(tokens: tokens,
            imagePlaceholderId: c.imageTokenIndex, imageSpanLengths: imageCounts,
            videoPlaceholderId: c.videoTokenIndex, videoSpanLengths: videoCounts)
        let imageSources = sources.filter { $0.kind == .image }
        let videoSources = sources.filter { $0.kind == .video }
        guard sources.count == imageSources.count + videoSources.count,
            sources.prefix(imageSources.count).allSatisfy({ $0.kind == .image }),
            imageSources.count == imageGrids.count, videoSources.count == videoGrids.count,
            !sources.isEmpty else { throw EngineV2VisionPrefillError.noProcessedMedia }
        let limits = towerLimits.withHeadFactor(VisionTowerBudget.attentionHeadFactor(
            hiddenSize: c.visionConfiguration.hiddenSize, numHeads: c.visionConfiguration.numHeads))
        var items: [ClusterQwenMedia.Item] = []
        let groups: [(ClusterQwenMedia.Kind, EngineV2VisionPrefill.SpanKind, MLXArray?, [THW], [Source])] = [
            (.image, .image, input.image?.pixels, imageGrids, imageSources),
            (.video, .video, input.video?.pixels, videoGrids, videoSources),
        ]
        for (kind, spanKind, pixels, grids, encoded) in groups {
            guard let pixels else {
                guard grids.isEmpty, encoded.isEmpty else { throw EngineV2VisionPrefillError.noProcessedMedia }
                continue
            }
            guard pixels.dtype == .float32, pixels.ndim == 2,
                pixels.dim(1) == ClusterQwenMedia.patchWidth else {
                throw EngineV2VisionPrefillError.unsupportedMedia("Qwen flattened patch geometry differs")
            }
            let ranges = try EngineV2VisionPrefill.imagePixelRuns(grids: grids, totalRows: pixels.dim(0))
            let matching = spans.filter { $0.kind == spanKind }
            guard matching.count == grids.count else {
                throw EngineV2VisionPrefillError.unsupportedMedia("Qwen media span count differs")
            }
            eval(pixels)
            try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
            let bytes = pixels.asData(access: .noCopyIfContiguous).data
            try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
            for (index, grid) in grids.enumerated() {
                let source = encoded[index], range = ranges[index], span = matching[index].span
                guard grid.t <= (kind == .image ? 1 : 4), range.count <= source.maximumPatches,
                    span.length == range.count / 4 else {
                    throw EngineV2VisionPrefillError.unsupportedMedia("Qwen preparation exceeds admitted geometry")
                }
                if case .reject(let reason) = VisionTowerBudget.admit(grids: [grid], subject: "Qwen media", limits: limits) {
                    throw EngineV2VisionPrefillError.towerBudgetExceeded(reason)
                }
                let stride = ClusterQwenMedia.patchWidth * MemoryLayout<Float>.stride
                let lower = bytes.startIndex + range.lowerBound * stride
                let upper = bytes.startIndex + range.upperBound * stride
                let patchBytes = bytes[lower..<upper]
                items.append(.init(kind: kind, sha256: ClusterQwenMedia.sha256(source.bytes),
                    byteCount: source.bytes.count, decodedPixels: source.decodedPixels, encoded: source.bytes,
                    temporal: grid.t, height: grid.h, width: grid.w,
                    tokenOffset: span.tokenOffset, tokenCount: span.length,
                    patchesSHA256: ClusterQwenMedia.sha256(patchBytes)))
            }
            withExtendedLifetime(pixels) {}
        }
        let position = try QwenVisionSeamSupport.positionResult(tokens: input.text.tokens,
            imageGrids: imageGrids.isEmpty ? nil : imageGrids,
            videoGrids: videoGrids.isEmpty ? nil : videoGrids,
            attentionMask: input.text.mask, seam: c.visionSeamConfiguration)
        guard position.promptPositionIds.dtype == .int32,
            position.promptPositionIds.shape == [3, 1, tokens.count], position.decodeState.deltas.count == 1 else {
            throw EngineV2VisionPrefillError.unsupportedMedia("Qwen three-axis position geometry differs")
        }
        eval(position.promptPositionIds)
        try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
        let media = ClusterQwenMedia(artifactSHA256: artifactSHA256,
            configurationSHA256: configurationSHA256, processorSHA256: processorSHA256,
            processorPolicy: .qwen35, promptLength: tokens.count,
            promptSHA256: ClusterQwenMedia.int32SHA256(tokens.map(Int32.init)),
            positionIDsSHA256: ClusterQwenMedia.int32SHA256(position.promptPositionIds.asArray(Int32.self)),
            decodeDeltas: position.decodeState.deltas, items: items)
        try media.validate(prompt: tokens, imageToken: c.imageTokenIndex, videoToken: c.videoTokenIndex,
            startToken: c.visionStartTokenId, endToken: c.visionEndTokenId, maximumPromptTokens: maximumPromptTokens)
        return .init(tokens: tokens, wire: try media.encoded(),
            mediaKind: imageGrids.isEmpty ? .video : videoGrids.isEmpty ? .image : .mixed)
    }
}
