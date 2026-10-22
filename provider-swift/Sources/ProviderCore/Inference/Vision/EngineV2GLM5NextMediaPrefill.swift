// Copyright © 2026 Eigen Labs.
//
// GLM-5.3-Flash media prefill for EngineV2.
//
// GLM's text tower has no positional encoding, so visual tokens are ordinary
// causal tokens at their cache offsets: the submission carries causal spans
// and no position state. The tower runs ONE temporal pair (one still image or
// two sampled video frames) at a time and tiles its attention queries, so no
// frame-square score tensor is allocated; every evaluation checks the scoped
// MLX fault box. The processor expands a video to one image-token span per
// temporal pair, each followed by its timestamp text, so a pair is placed
// exactly like an image. Geometry and placements are validated before any
// tower work.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

extension EngineV2VisionPrefill {
    /// Decode with the existing bounded ingest, but preserve GLM's native
    /// tool/history values and interleaved symbolic media parts. No URL or media
    /// bytes enter the prompt, and non-user media is rejected rather than lost.
    static func glm5NextUserInput(request: OpenAIChatCompletionRequest,
                                  controls: ChatTemplateControls) async throws -> UserInput {
        var textRequest = request
        for index in request.messages.indices {
            let message = request.messages[index]
            if case .parts(let parts) = message.content {
                for part in parts {
                    switch part {
                    case .text: break
                    case .imageURL, .videoURL:
                        guard message.role == .user else {
                            throw EngineV2VisionPrefillError.unsupportedMedia("GLM media requires a user role")
                        }
                    case .inputAudio, .unsupported:
                        throw EngineV2VisionPrefillError.unsupportedMedia("GLM supports image/video parts only")
                    }
                }
            }
            textRequest.messages[index].content = .text(message.textContent)
        }
        let prepared = try ToolChoicePromptPolicy.prepare(textRequest, modelType: "glm5_next")
        let normalized = try GLM5NextPromptPolicy.normalizedTextInput(request: textRequest,
            prepared: prepared, controls: controls)
        var messages = normalized.messages
        let prefix = messages.count - request.messages.count
        guard (0...1).contains(prefix) else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM prompt alignment")
        }
        for index in request.messages.indices {
            let message = request.messages[index]
            guard message.role == .user, case .parts(let parts) = message.content else { continue }
            messages[index + prefix]["content"] = try parts.map { part -> [String: String] in
                switch part {
                case .text(let text): return ["type": "text", "text": text]
                case .imageURL: return ["type": "image"]
                case .videoURL: return ["type": "video"]
                case .inputAudio, .unsupported:
                    throw EngineV2VisionPrefillError.unsupportedMedia("GLM supports image/video parts only")
                }
            }
        }
        let decoded = try await MediaIngest.buildUserInput(from: request, templateControls: controls)
        return UserInput(messages: messages, images: decoded.images, videos: decoded.videos,
            tools: normalized.tools, additionalContext: normalized.additionalContext)
    }

    /// Serving media preparation for a loaded GLM root and its processor.
    /// Deterministic input faults map to `unsupportedMedia` (HTTP 400); tower
    /// and MLX faults keep the retriable refusal mapping.
    static func prepareGLM5NextMedia(
        container: ModelContainer, request: OpenAIChatCompletionRequest,
        templateControls: ChatTemplateControls
    ) async throws -> PreparedSubmission {
        let input = try await glm5NextUserInput(request: request, controls: templateControls)
        let limits = VisionTowerBudget.liveLimits
        return try await container.perform(nonSendable: input) { context, input in
            guard let root = context.model as? GLM5NextModel,
                let processor = context.processor as? GLM5NextProcessor
            else {
                throw EngineV2VisionPrefillError.unsupportedVLM("GLM managed processor identity")
            }
            do {
                return try await MLX.withError { errors in
                    let prepared: GLM5NextPreparedInput
                    do {
                        prepared = try await processor.prepareDetailed(input: input)
                    } catch let error as GLM5NextVisionError {
                        throw glm5NextInputError(error)
                    }
                    try throwIfMLXFaulted(errors)
                    return try buildGLM5NextSubmission(
                        root: root, prepared: prepared, towerLimits: limits, mlxErrors: errors)
                }
            } catch let error as MLX.MLXError { throw visionPrefillError(for: error) }
        }
    }

    /// Processor refusals are properties of the request (geometry, counts,
    /// budgets), identical on every provider. Their details are code literals.
    static func glm5NextInputError(_ error: GLM5NextVisionError) -> Error {
        switch error {
        case .invalidInput(let detail), .budgetExceeded(let detail), .unsupported(let detail):
            return EngineV2VisionPrefillError.unsupportedMedia("GLM media input: \(detail)")
        case .invalidWeights, .weightsNotLoaded:
            return error
        }
    }

    private struct GLMFrameFeature {
        let modality: GLM5NextMediaPlacement.Modality
        let item: Int
        let range: Range<Int>
        let value: MLXArray
    }

    static func buildGLM5NextSubmission(root: GLM5NextModel, prepared: GLM5NextPreparedInput,
        towerLimits: VisionTowerBudget.Limits, mlxErrors: MLX.ErrorBox) throws -> PreparedSubmission {
        let input = prepared.input
        guard input.image != nil || input.video != nil else { throw EngineV2VisionPrefillError.noProcessedMedia }
        guard input.text.tokens.ndim == 2, input.text.tokens.dim(0) == 1,
            input.text.tokens.dim(1) > 0, input.text.tokens.dim(1) <= root.configuration.textConfig.maxPositionEmbeddings else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM media requires a bounded single prompt")
        }
        let tokenArray = input.text.tokens.asType(.int64)
        eval(tokenArray)
        try throwIfMLXFaulted(mlxErrors)
        let tokens = tokenArray.asArray(Int64.self).map(Int.init)
        try throwIfMLXFaulted(mlxErrors)
        guard tokens.allSatisfy({ (0..<root.vocabularySize).contains($0) }) else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM token outside vocabulary")
        }
        if let mask = input.text.mask {
            guard mask.shape == input.text.tokens.shape, mask.dtype == .bool else {
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM validity mask geometry")
            }
            eval(mask)
            try throwIfMLXFaulted(mlxErrors)
            let valid = mask.asArray(Bool.self)
            try throwIfMLXFaulted(mlxErrors)
            guard valid.allSatisfy({ $0 }) else {
                // CBv2's one-row submission has no padding-validity field. Do
                // not silently strip padding and move GLM sparse-pool origins.
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM padded media requires request validity support")
            }
        }
        let vision = root.configuration.visionConfig
        let patchWidth = vision.inChannels * vision.temporalPatchSize * vision.patchSize * vision.patchSize
        var frames: [GLMFrameFeature] = []
        var expected: [(GLM5NextMediaPlacement.Modality, Int, Range<Int>)] = []
        var aggregatePatches = 0
        let sources: [(GLM5NextMediaPlacement.Modality, MLXArray?, [THW]?)] = [
            (.image, input.image?.pixels, input.image?.frames),
            (.video, input.video?.pixels, input.video?.frames),
        ]
        // Validate ALL geometry/placements before any tower invocation.
        for (modality, pixels, grids) in sources {
            guard let pixels else { continue }
            guard let grids, !grids.isEmpty, pixels.ndim == 2 else {
                throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: 0)
            }
            guard pixels.dtype.isFloatingPoint, pixels.dim(1) == patchWidth else {
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM flattened patch geometry")
            }
            _ = try imagePixelRuns(grids: grids, totalRows: pixels.dim(0))
            var feature = 0
            for (item, grid) in grids.enumerated() {
                guard grid.t > 0, modality != .image || grid.t == 1,
                    let count = VisionTowerBudget.patchCount(grid), count <= 960_000 - aggregatePatches else {
                    throw EngineV2VisionPrefillError.towerBudgetExceeded("GLM aggregate patch limit")
                }
                aggregatePatches += count
                let one = THW(1, grid.h, grid.w)
                _ = try VisionTowerBudget.glm5FrameLimits(grid: one,
                    configuration: vision, limits: towerLimits)
                let perFrame = count / grid.t / 4
                for _ in 0..<grid.t {
                    expected.append((modality, item, feature..<(feature + perFrame)))
                    feature += perFrame
                }
            }
        }
        let placements = prepared.placements.sorted { $0.tokenRange.lowerBound < $1.tokenRange.lowerBound }
        guard placements.count == expected.count else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM frame/placement count")
        }
        var occupied = Set<Int>()
        var matched = Set<Int>()
        var lastImage = -1
        var lastVideo = -1
        for p in placements {
            guard p.tokenRange.lowerBound >= 0, p.tokenRange.upperBound <= tokens.count,
                !p.tokenRange.isEmpty, p.tokenRange.count == p.featureRange.count,
                p.tokenRange.allSatisfy({ tokens[$0] == root.configuration.imageTokenId && occupied.insert($0).inserted }),
                let index = expected.indices.first(where: {
                    expected[$0].0 == p.modality && expected[$0].1 == p.itemIndex && expected[$0].2 == p.featureRange
                }), matched.insert(index).inserted else {
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM exact token/feature placement")
            }
            if p.modality == .image {
                guard index > lastImage else { throw EngineV2VisionPrefillError.unsupportedMedia("GLM image order") }
                lastImage = index
            } else {
                guard index > lastVideo else { throw EngineV2VisionPrefillError.unsupportedMedia("GLM video order") }
                lastVideo = index
            }
        }
        guard !tokens.contains(root.configuration.videoTokenId),
            tokens.indices.allSatisfy({ tokens[$0] != root.configuration.imageTokenId || occupied.contains($0) }) else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM unexpanded or uncovered media token")
        }
        for (modality, pixels, grids) in sources {
            guard let pixels, let grids else { continue }
            // Geometry and placements were validated above, before any tower work.
            let runs = try imagePixelRuns(grids: grids, totalRows: pixels.dim(0))
            var feature = 0
            for (item, grid) in grids.enumerated() {
                let perFrame = runs[item].count / grid.t
                for frame in 0..<grid.t {
                    try Task.checkCancellation()
                    let limits = try VisionTowerBudget.glm5FrameLimits(grid: THW(1, grid.h, grid.w),
                        configuration: vision, limits: towerLimits)
                    let start = runs[item].lowerBound + frame * perFrame
                    let value = try root.visionTower.forward(patches: pixels[start..<(start + perFrame)],
                        grids: [GLM5NextVisionGrid(temporal: 1, height: grid.h, width: grid.w)],
                        limits: limits, checkpoint: { _ in
                            try Task.checkCancellation()
                            try throwIfMLXFaulted(mlxErrors)
                        }).expandedDimensions(axis: 0)
                    eval(value)
                    try throwIfMLXFaulted(mlxErrors)
                    guard value.shape == [1, perFrame / 4, root.configuration.textConfig.hiddenSize] else {
                        throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: modality == .image ? .image : .video)
                    }
                    frames.append(.init(modality: modality, item: item, range: feature..<(feature + perFrame / 4), value: value))
                    feature += perFrame / 4
                }
            }
        }
        let embeddings = try placements.map { p -> MLXArray in
            guard let frame = frames.first(where: { $0.modality == p.modality && $0.item == p.itemIndex && $0.range == p.featureRange }) else {
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM missing frame features")
            }
            return frame.value
        }
        return PreparedSubmission(promptTokens: tokens,
            spans: placements.map { .init(tokenOffset: $0.tokenRange.lowerBound, length: $0.tokenRange.count) },
            embeddings: embeddings, spanKinds: placements.map { $0.modality == .image ? .image : .video },
            attention: .causal, positionState: nil,
            mediaKind: input.image == nil ? .video : input.video == nil ? .image : .mixed)
    }
}

extension EngineV2Bridge {
    /// Whether this GLM slot's engine accepts prepared causal media rows: the
    /// target-only engine (`GLM5NextSteppableModel` over the causal bank), or
    /// a protected native engine whose issued contract grants it. Checked
    /// before any decode or tower work.
    var servesGLM5NextMedia: Bool { glm5NextNativeOwner?.servesPreparedCausalMedia ?? true }
}
