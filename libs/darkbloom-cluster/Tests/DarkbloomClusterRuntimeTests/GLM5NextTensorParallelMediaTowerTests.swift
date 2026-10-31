import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import DarkbloomClusterRuntime

/// Rank 0's media path (`startPreparation`, then `open`: the tower per
/// temporal pair) against the product's own loop (`buildGLM5NextSubmission`:
/// `prepareDetailed`, then one tower call per temporal pair with
/// `glm5FrameLimits`) on the real vision tower, bit for bit. The sum is the
/// identity here (one rank); the pair's sum adds negative zero
/// (`GLM5NextTensorParallelMediaTests`).
/// Needs the GPU and the artifact's vision shard (1.1 GB) only:
/// `GLM53_MODEL_DIR=<artifact dir> GLM53_MEDIA="<image> <video>"`.
@Suite("GLM tensor-parallel media on the real vision tower",
       .enabled(if: ProcessInfo.processInfo.environment["GLM53_MODEL_DIR"] != nil), .serialized)
struct GLM5NextTensorParallelMediaTowerTests {
    struct Tokenizer: MLXLMCommon.Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map { Int($0) } }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
        func convertTokenToId(_ token: String) -> Int? {
            ["<|image|>": 154854, "<|video|>": 154855, "<|begin_of_image|>": 154830, "<|end_of_image|>": 154831,
             "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833][token]
        }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            var tokens = [1]
            for message in messages {
                for part in message["content"] as? [[String: any Sendable]] ?? [] {
                    switch part["type"] as? String {
                    case "image": tokens += [154830, 154854, 154831]
                    case "video": tokens += [154832, 154855, 154833]
                    default: tokens += [2]
                    }
                }
            }
            return tokens + [3]
        }
    }

    /// The product's per-frame limits (`VisionTowerBudget.glm5FrameLimits`, no operator ceiling).
    static func limits(height: Int, width: Int, heads: Int) -> GLM5NextVisionLimits {
        let patches = height * width
        let scores = min(32_000_000, GPU.deviceInfo().maxBufferSize / 4)
        return .init(maximumPatches: 32_000, maximumFramePatches: 32_000,
            maximumQueryTokens: min(128, min(patches, scores / heads / patches)), maximumScoreElements: scores)
    }

    @Test func rankZeroFeaturesAreTheProductLoopsBitForBit() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["GLM53_MODEL_DIR"]))
        let paths = (environment["GLM53_MEDIA"] ?? "").split(separator: " ").map(String.init)
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let v = configuration.visionConfig
        let tower = try GLM5NextVisionTower(configuration: v)
        let weights = try MLX.loadArrays(url: directory.appendingPathComponent("model-00035-of-00035.safetensors"))
            .filter { $0.key.hasPrefix("model.visual.") }
        try tower.loadNativeWeights(weights, dtype: .bfloat16)
        let encoded = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let kinds: [ClusterGLMMedia.Kind] = paths.map { $0.hasSuffix(".mp4") || $0.hasSuffix(".mov") ? .video : .image }
        func values() throws -> ([UserInput.Image], [UserInput.Video]) {
            var images: [UserInput.Image] = [], videos: [UserInput.Video] = []
            for (data, kind) in zip(encoded, kinds) {
                if kind == .image { images.append(try GLM5NextTensorParallelMedia.image(data)) }
                else { videos.append(.memoryBacked(try MemoryBackedVideoAsset(videoData: data))) }
            }
            return (images, videos)
        }
        let processorConfiguration = try GLM5NextProcessorConfiguration(patchSize: v.patchSize)
        // The product: prepareDetailed, then the tower once per temporal pair.
        let (images, videos) = try values()
        let detailed = try await GLM5NextProcessor(configuration: processorConfiguration, tokenizer: Tokenizer())
            .prepareDetailed(input: UserInput(chat: [.user("x", images: images, videos: videos)]))
        var product: [MLXArray] = []
        var items: [ClusterGLMMedia.Item] = []
        let placements = detailed.placements.sorted { $0.tokenRange.lowerBound < $1.tokenRange.lowerBound }
        let blocks: [(GLM5NextMediaPlacement.Modality, ClusterGLMMedia.Kind, MLXArray?, [THW])] = [
            (.image, .image, detailed.input.image?.pixels, detailed.input.image?.frames ?? []),
            (.video, .video, detailed.input.video?.pixels, detailed.input.video?.frames ?? []),
        ]
        for (modality, kind, pixels, grids) in blocks {
            guard let pixels else { continue }
            var row = 0, feature = 0
            let data = encoded.enumerated().filter { kinds[$0.offset] == kind }.map(\.element)
            for (item, grid) in grids.enumerated() {
                let rows = grid.h * grid.w, limits = Self.limits(height: grid.h, width: grid.w, heads: v.numHeads)
                let start = row
                var offsets: [Int] = []
                for _ in 0 ..< grid.t {
                    let value = try tower.forward(patches: pixels[row ..< (row + rows)],
                        grids: [GLM5NextVisionGrid(temporal: 1, height: grid.h, width: grid.w)], limits: limits)
                    eval(value)
                    product.append(value)
                    let p = try #require(placements.first {
                        $0.modality == modality && $0.itemIndex == item && $0.featureRange.lowerBound == feature
                    })
                    offsets.append(p.tokenRange.lowerBound)
                    feature += rows / 4; row += rows
                }
                items.append(.init(kind: kind, sha256: ClusterGLMMedia.sha256(data[item]), byteCount: data[item].count,
                    encoded: data[item], temporal: grid.t, height: grid.h, width: grid.w, maximumPatches: limits.maximumPatches,
                    maximumQueryTokens: limits.maximumQueryTokens, maximumScoreElements: limits.maximumScoreElements,
                    patchesSHA256: GLM5NextTensorParallelMedia.digest(pixels[start ..< row].asArray(Float.self)),
                    tokenOffsets: offsets))
            }
        }
        // Rank 0, from the encoded bytes and the description alone.
        let tokens = detailed.input.text.tokens.asType(.int64).asArray(Int64.self).map(Int.init)
        let media = try GLM5NextTensorParallelMedia(media: ClusterGLMMedia(configurationSHA256: String(repeating: "0", count: 64),
            processor: .init(patchSize: v.patchSize, imageMinimumTokens: processorConfiguration.imageMinimumTokens,
                imageMaximumTokens: processorConfiguration.imageMaximumTokens,
                videoMinimumTokens: processorConfiguration.videoMinimumTokens,
                videoMaximumTokens: processorConfiguration.videoMaximumTokens), items: items),
            prompt: tokens, configuration: configuration)
        media.startPreparation()
        #expect(try media.open(rank: 0, tower: tower, sum: { $0 }, stop: { false }))
        #expect(media.shared.count == product.count && !product.isEmpty)
        for (cluster, reference) in zip(media.shared, product) {
            #expect(cluster.shape == reference.shape && cluster.dtype == reference.dtype)
            #expect(MLX.all(view(cluster, dtype: .uint16) .== view(reference, dtype: .uint16)).item(Bool.self))
        }
        print("glm-tp-media-tower frames=\(product.count) tokens=\(media.featureCount) bitwise=ok")
    }
}
