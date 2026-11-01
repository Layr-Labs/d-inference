import Foundation
import CryptoKit
import DarkbloomClusterProtocol
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// The leader's half of GLM-5.3-Flash images and video on the tensor-parallel
/// pair (`ClusterGLMMedia`). It runs the single-Mac product's own media path
/// up to its vision tower: `EngineV2VisionPrefill.glm5NextUserInput` (the
/// bounded media decode and every product cap) and
/// `GLM5NextProcessor.prepareDetailed` with the artifact's processor budgets
/// and the product's thinking-off tokenizer, so the expanded prompt, its
/// spans and the patches are the product's. It checks the result as
/// `buildGLM5NextSubmission` does before its tower, and describes it for the
/// ranks: rank 0 gets the encoded bytes, both get the spans, the product's
/// tower limits per frame and a digest of each item's patches, which rank 0
/// must reproduce. The patches themselves never leave this process.
public struct DistributedGLMMediaIngress: Sendable {
    let configuration: GLM5NextConfiguration
    let configurationSHA256: String
    let processor: GLM5NextProcessorConfiguration
    let processorBudgets: ClusterGLMMedia.Processor

    struct Prepared {
        let tokens: [Int]
        let wire: Data
        let mediaKind: EngineV2MediaKind
    }

    init(configuration bytes: Data, processorConfiguration processorBytes: Data, expectedSHA256: String) throws {
        guard !bytes.isEmpty, bytes.count <= 32 * 1024 * 1024,
              ClusterGLMMedia.sha256(bytes) == expectedSHA256 else {
            throw DistributedEngineError.invalidConfiguration("GLM media configuration differs from loaded peers")
        }
        configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: bytes)
        configurationSHA256 = expectedSHA256
        guard configuration.imageTokenId == GLM5NextProcessor.imageToken,
              configuration.videoTokenId == GLM5NextProcessor.videoToken,
              configuration.imageStartTokenId == 154830, configuration.imageEndTokenId == 154831,
              configuration.textConfig.dtype == "bfloat16",
              configuration.visionConfig.outHiddenSize == configuration.textConfig.hiddenSize else {
            throw DistributedEngineError.invalidConfiguration("GLM native media markers or widths differ")
        }
        processor = try Self.processorConfiguration(processorBytes, configuration: configuration)
        processorBudgets = .init(patchSize: processor.patchSize, imageMinimumTokens: processor.imageMinimumTokens,
            imageMaximumTokens: processor.imageMaximumTokens, videoMinimumTokens: processor.videoMinimumTokens,
            videoMaximumTokens: processor.videoMaximumTokens)
    }

    /// The single-Mac product's processor contract
    /// (`GLM5NextArtifactPlan.processorConfiguration`): the same accepted
    /// fields, pixel contract and 2 FPS video sampling, the same budgets.
    static func processorConfiguration(_ data: Data, configuration: GLM5NextConfiguration) throws
        -> GLM5NextProcessorConfiguration
    {
        func refuse(_ detail: String) -> Error { DistributedEngineError.invalidConfiguration("GLM processor: " + detail) }
        guard data.count <= 1 << 20, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["processor_class", "image_processor", "video_processor"] else { throw refuse("fields") }
        let allowed: Set<String> = [
            "do_rescale", "patch_expand_factor", "merge_size", "image_mean", "image_std",
            "temporal_patch_size", "patch_size", "min_image_tokens", "max_image_tokens", "fps",
            "image_processor_type", "video_processor_type",
        ]
        for (name, typeKey, expectedType) in [
            ("image_processor", "image_processor_type", "Glm5NextImageProcessor"),
            ("video_processor", "video_processor_type", "Glm5NextVideoProcessor"),
        ] {
            guard let fields = raw[name] as? [String: Any], Set(fields.keys).isSubset(of: allowed),
                  fields[typeKey] as? String == expectedType else { throw refuse("unsupported mode") }
        }
        struct Processor: Decodable {
            struct Media: Decodable {
                let doRescale: Bool, patchExpandFactor: Int, mergeSize: Int
                let imageMean: [Float], imageStd: [Float]
                let temporalPatchSize: Int, patchSize: Int, minImageTokens: Int, maxImageTokens: Int
                let fps: Double?
                enum CodingKeys: String, CodingKey {
                    case doRescale = "do_rescale", patchExpandFactor = "patch_expand_factor", mergeSize = "merge_size"
                    case imageMean = "image_mean", imageStd = "image_std"
                    case temporalPatchSize = "temporal_patch_size", patchSize = "patch_size"
                    case minImageTokens = "min_image_tokens", maxImageTokens = "max_image_tokens", fps
                }
            }
            let processorClass: String
            let imageProcessor: Media
            let videoProcessor: Media
            enum CodingKeys: String, CodingKey {
                case processorClass = "processor_class", imageProcessor = "image_processor"
                case videoProcessor = "video_processor"
            }
        }
        let p = try JSONDecoder().decode(Processor.self, from: data)
        guard p.processorClass == "Glm5NextProcessor", p.videoProcessor.fps == 2 else { throw refuse("class/sampling") }
        for m in [p.imageProcessor, p.videoProcessor] {
            guard m.doRescale, m.patchExpandFactor == 1,
                  m.mergeSize == configuration.visionConfig.spatialMergeSize,
                  m.temporalPatchSize == configuration.visionConfig.temporalPatchSize,
                  m.patchSize == configuration.visionConfig.patchSize,
                  m.imageMean == GLM5NextProcessor.mean, m.imageStd == GLM5NextProcessor.standardDeviation else {
                throw refuse("pixel contract")
            }
        }
        return try .init(
            patchSize: p.imageProcessor.patchSize,
            imageMinimumTokens: p.imageProcessor.minImageTokens, imageMaximumTokens: p.imageProcessor.maxImageTokens,
            videoMinimumTokens: p.videoProcessor.minImageTokens, videoMaximumTokens: p.videoProcessor.maxImageTokens)
    }

    /// One request: the product's prompt and patches, checked, described.
    /// Input faults throw what the product throws for them (`MediaError`,
    /// `EngineV2VisionPrefillError.unsupportedMedia`, ...), so the scheduler
    /// maps them to the same HTTP answers.
    func prepare(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
                 tokenizer: any Tokenizer) async throws -> Prepared {
        let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: controls)
        // The encoded bytes in the order the ingest decoded them: user
        // messages' parts in order (media on other roles was refused above).
        var imageBytes: [Data] = [], videoBytes: [Data] = []
        for message in request.messages where message.role == .user {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .imageURL(let uri): imageBytes.append(try MediaIngest.dataFromDataURI(uri))
                case .videoURL(let uri): videoBytes.append(try MediaIngest.dataFromDataURI(uri))
                default: break
                }
            }
        }
        guard imageBytes.count == input.images.count, videoBytes.count == input.videos.count,
              imageBytes.count + videoBytes.count > 0 else { throw EngineV2VisionPrefillError.noProcessedMedia }
        guard imageBytes.count + videoBytes.count <= ClusterGLMMedia.maximumImages + ClusterGLMMedia.maximumVideos,
              imageBytes.reduce(0, { $0 + $1.count }) + videoBytes.reduce(0, { $0 + $1.count })
                <= ClusterGLMMedia.maximumEncodedBytes else {
            throw MediaIngest.MediaError.mediaTooLarge("request media exceeds the pair's \(ClusterGLMMedia.maximumEncodedBytes) bytes")
        }
        // The product renders through its thinking-off tokenizer.
        let serving: any Tokenizer = try (tokenizer as? GLM5NextThinkingTokenizer)
            ?? GLM5NextThinkingTokenizer(base: tokenizer)
        let processor = try GLM5NextProcessor(configuration: self.processor, tokenizer: serving)
        // Patches are host values copied into arrays; the CPU device leaves the
        // GPU to the ranks on this Mac and gives the same bits.
        await Self.gate.acquire()
        do {
            let value = try await Device.withDefaultDevice(.cpu) {
                let prepared: GLM5NextPreparedInput
                do { prepared = try await processor.prepareDetailed(input: input) }
                catch let error as GLM5NextVisionError { throw EngineV2VisionPrefill.glm5NextInputError(error) }
                return try describe(prepared, images: imageBytes, videos: videoBytes)
            }
            await Self.gate.release()
            return value
        } catch {
            await Self.gate.release()
            throw error
        }
    }

    /// `buildGLM5NextSubmission`'s checks before its tower, then the envelope.
    func describe(_ prepared: GLM5NextPreparedInput, images imageBytes: [Data], videos videoBytes: [Data],
                  towerLimits: VisionTowerBudget.Limits = VisionTowerBudget.liveLimits) throws -> Prepared {
        let input = prepared.input
        let c = configuration
        guard input.image != nil || input.video != nil else { throw EngineV2VisionPrefillError.noProcessedMedia }
        guard input.text.tokens.ndim == 2, input.text.tokens.dim(0) == 1, input.text.tokens.dim(1) > 0,
              input.text.tokens.dim(1) <= c.textConfig.maxPositionEmbeddings else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM media requires a bounded single prompt")
        }
        let tokens = input.text.tokens.asType(.int64).asArray(Int64.self).map(Int.init)
        guard tokens.allSatisfy({ (0 ..< c.textConfig.vocabularySize).contains($0) }) else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM token outside vocabulary")
        }
        if let mask = input.text.mask {
            guard mask.shape == input.text.tokens.shape, mask.dtype == .bool, mask.asArray(Bool.self).allSatisfy({ $0 }) else {
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM padded media requires request validity support")
            }
        }
        let vision = c.visionConfig
        let patchWidth = vision.inChannels * vision.temporalPatchSize * vision.patchSize * vision.patchSize
        var items: [ClusterGLMMedia.Item] = []
        var aggregatePatches = 0
        let sources: [(GLM5NextMediaPlacement.Modality, ClusterGLMMedia.Kind, MLXArray?, [THW]?, [Data])] = [
            (.image, .image, input.image?.pixels, input.image?.frames, imageBytes),
            (.video, .video, input.video?.pixels, input.video?.frames, videoBytes),
        ]
        let placements = prepared.placements.sorted { $0.tokenRange.lowerBound < $1.tokenRange.lowerBound }
        var matched = 0
        for (modality, kind, pixels, grids, encoded) in sources {
            guard let pixels else {
                guard encoded.isEmpty else { throw EngineV2VisionPrefillError.noProcessedMedia }
                continue
            }
            guard let grids, grids.count == encoded.count, pixels.ndim == 2 else {
                throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: 0)
            }
            guard pixels.dtype == .float32, pixels.dim(1) == patchWidth else {
                throw EngineV2VisionPrefillError.unsupportedMedia("GLM flattened patch geometry")
            }
            let runs = try EngineV2VisionPrefill.imagePixelRuns(grids: grids, totalRows: pixels.dim(0))
            // Contiguous float32 rows: each item's patches are a byte range.
            let bytes = pixels.asData(access: .noCopyIfContiguous).data
            var feature = 0
            for (item, grid) in grids.enumerated() {
                guard grid.t > 0, modality != .image || grid.t == 1,
                      let count = VisionTowerBudget.patchCount(grid), count <= 960_000 - aggregatePatches else {
                    throw EngineV2VisionPrefillError.towerBudgetExceeded("GLM aggregate patch limit")
                }
                aggregatePatches += count
                let limits = try VisionTowerBudget.glm5FrameLimits(grid: THW(1, grid.h, grid.w),
                    configuration: vision, limits: towerLimits)
                let perFrame = count / grid.t / 4
                var offsets: [Int] = []
                for _ in 0 ..< grid.t {
                    let range = feature ..< (feature + perFrame)
                    guard let p = placements.first(where: {
                        $0.modality == modality && $0.itemIndex == item && $0.featureRange == range
                    }), p.tokenRange.count == perFrame, p.tokenRange.upperBound <= tokens.count,
                          p.tokenRange.allSatisfy({ tokens[$0] == c.imageTokenId }) else {
                        throw EngineV2VisionPrefillError.unsupportedMedia("GLM exact token/feature placement")
                    }
                    offsets.append(p.tokenRange.lowerBound); feature += perFrame; matched += 1
                }
                let rows = runs[item]
                let patches = bytes[(bytes.startIndex + rows.lowerBound * patchWidth * 4)
                    ..< (bytes.startIndex + rows.upperBound * patchWidth * 4)]
                let data = encoded[item]
                items.append(.init(kind: kind, sha256: ClusterGLMMedia.sha256(data), byteCount: data.count, encoded: data,
                    temporal: grid.t, height: grid.h, width: grid.w, maximumPatches: limits.maximumPatches,
                    maximumQueryTokens: limits.maximumQueryTokens, maximumScoreElements: limits.maximumScoreElements,
                    patchesSHA256: SHA256.hash(data: patches).map { String(format: "%02x", $0) }.joined(),
                    tokenOffsets: offsets))
            }
            withExtendedLifetime(pixels) {}
        }
        guard matched == placements.count else {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM frame/placement count")
        }
        let media = ClusterGLMMedia(configurationSHA256: configurationSHA256, processor: processorBudgets, items: items)
        do {
            try media.validate(prompt: tokens, imageToken: c.imageTokenId, startToken: c.imageStartTokenId,
                endToken: c.imageEndTokenId, videoToken: c.videoTokenId)
        } catch {
            throw EngineV2VisionPrefillError.unsupportedMedia("GLM unexpanded or uncovered media token")
        }
        return .init(tokens: tokens, wire: try media.encoded(),
            mediaKind: input.image == nil ? .video : input.video == nil ? .image : .mixed)
    }

    /// One preparation at a time on the leader: its decoded frames and patches
    /// (the processor's 512 MiB caps, twice) are transient host memory beside
    /// the rank this Mac holds.
    static let gate = DistributedGLMMediaGate()
}

/// Serializes the leader's media preparations (FIFO).
actor DistributedGLMMediaGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to the next waiter, or frees the gate.
    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
