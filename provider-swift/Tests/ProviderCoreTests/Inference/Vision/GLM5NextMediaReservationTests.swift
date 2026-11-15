// Copyright © 2026 Eigen Labs.
//
// GLM-5.3-Flash's media memory reservation priced from each image's header
// and each video's container: the quote against the real GLM processor's
// rendering, the processor's ceilings when geometry can't be read or the
// switch is off, and the media gate's decision either way. No model weights.

@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

/// GLM's media-token identities; text renders one token per scalar, so a
/// timestamp renders one token per byte, the quote's own bound.
private struct GLMRenderTokenizer: MLXLMCommon.Tokenizer {
    private static let specials = [
        "<|image|>": 154854, "<|video|>": 154855,
        "<|begin_of_image|>": 154830, "<|end_of_image|>": 154831,
        "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833,
    ]
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func convertTokenToId(_ token: String) -> Int? { Self.specials[token] }
    func convertIdToToken(_ id: Int) -> String? { Self.specials.first { $0.value == id }?.key }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        messages.flatMap { message -> [Int] in
            guard let parts = message["content"] as? [[String: String]] else {
                return encode(text: message["content"] as? String ?? "", addSpecialTokens: false)
            }
            return parts.flatMap { part -> [Int] in
                switch part["type"] {
                case "image": [154830, 154854, 154831]
                case "video": [154832, 154855, 154833]
                default: encode(text: part["text"] ?? "", addSpecialTokens: false)
                }
            }
        }
    }
}

private func visionConfiguration() throws -> GLM5NextVisionConfiguration {
    try JSONDecoder().decode(
        GLM5NextVisionConfiguration.self,
        from: Data(
            #"""
            {"model_type":"glm5_next_vision","depth":24,"hidden_size":1024,"intermediate_size":4096,
             "num_heads":16,"out_hidden_size":4096,"patch_size":14,"projection_intermediate_size":10240,
             "spatial_merge_size":2,"temporal_patch_size":2,"in_channels":3,"attention_bias":true,
             "attention_dropout":0.0,"rms_norm_eps":1e-5,"swiglu_limit":10.0,"hidden_act":"silu",
             "image_size":448,"initializer_range":0.02}
            """#.utf8))
}

/// A solid sRGB PNG of `width` x `height`.
private func pngDataURI(width: Int, height: Int) throws -> String {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return "data:image/png;base64," + (data as Data).base64EncodedString()
}

/// OpenRouter's provider-readiness clip, kept as an SDK test resource.
private func readinessClip() throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent(
        "libs/mlx-swift-lm/Tests/MLXLMTests/Resources/MiMoOpenRouter/input-video-url.mp4"))
    #expect(
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            == "dc11648bd3546cd0a37ecc1077ccc426d42c409fe4822ece0354eb250804431e")
    return data
}

/// `movie` with its track header's display matrix set to `a b / c d`
/// (16.16 fixed point), no translation and no perspective.
private func withTrackMatrix(_ movie: Data, a: Int32, b: Int32, c: Int32, d: Int32) throws -> Data {
    var data = movie
    let type = try #require(data.range(of: Data("tkhd".utf8)))
    let content = type.upperBound - data.startIndex
    let version = data[data.startIndex + content]
    let matrix = content + 4 + (version == 1 ? 32 : 20) + 16
    for (index, value) in [a, b, 0, c, d, 0, 0, 0, 0x4000_0000].enumerated() {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: value).bigEndian) { Data($0) }
        let at = data.startIndex + matrix + 4 * index
        data.replaceSubrange(at ..< at + 4, with: bytes)
    }
    return data
}

private let one: Int32 = 0x0001_0000

private func videoPart(_ movie: Data) -> OpenAIContentPart {
    .videoURL("data:video/mp4;base64," + movie.base64EncodedString())
}

/// Decoded bytes of a `data:` URI's base64 payload.
private func encodedBytes(_ uri: String) throws -> UInt64 {
    let comma = try #require(uri.firstIndex(of: ","))
    let payload = try #require(Data(base64Encoded: String(uri[uri.index(after: comma)...])))
    return UInt64(payload.count)
}

private func request(_ parts: [OpenAIContentPart], maxTokens: Int = 65_536) -> OpenAIChatCompletionRequest {
    OpenAIChatCompletionRequest(
        model: "test/glm-stub",
        messages: [
            .init(role: .system, content: .text("Answer briefly.")),
            .init(role: .user, content: .parts([.text("Which color?")] + parts)),
        ],
        temperature: 0, maxTokens: maxTokens)
}

private let contextLength = 262_144

/// The scheduler's generic projection for `request`.
private func generic(_ request: OpenAIChatCompletionRequest) -> GLM5NextVisionBudget.Reservation {
    .init(
        bytes: MediaIngest.projectedDecodeBytes(request),
        kvTokens: MediaIngest.projectedKVTokens(request, defaultMaxTokens: 64, contextLength: contextLength))
}

private func quote(
    _ request: OpenAIChatCompletionRequest, environment: [String: String] = [:]
) async throws -> GLM5NextVisionBudget.Reservation {
    try await GLM5NextVisionBudget.mediaReservation(
        request: request, vision: visionConfiguration(), processor: GLM5NextProcessorConfiguration(),
        defaultMaxTokens: 64, contextLength: contextLength, generic: generic(request),
        environment: environment)
}

/// 0.10.13's charge: the generic projection plus the processor's ceilings.
private func ceiling(_ request: OpenAIChatCompletionRequest) throws -> GLM5NextVisionBudget.Reservation {
    let ceiling = try GLM5NextVisionBudget.reservation(
        request: request, vision: visionConfiguration(), processor: GLM5NextProcessorConfiguration(),
        defaultMaxTokens: 64, contextLength: contextLength)
    let base = generic(request)
    let (bytes, overflow) = base.bytes.addingReportingOverflow(ceiling.bytes)
    return .init(bytes: overflow ? .max : bytes, kvTokens: max(base.kvTokens, ceiling.kvTokens))
}

/// The tokens the real GLM processor renders for `request`'s one image or
/// video, from its begin token to its end token, and its placement count.
private func rendered(_ request: OpenAIChatCompletionRequest) async throws -> (tokens: Int, spans: Int) {
    let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: .init())
    let processor = try GLM5NextProcessor(configuration: .init(), tokenizer: GLMRenderTokenizer())
    return try await Device.withDefaultDevice(.cpu) {
        let output = try await processor.prepareDetailed(input: input)
        let tokens = output.input.text.tokens.asType(.int64).asArray(Int64.self).map(Int.init)
        let video = output.input.video != nil
        let begin = try #require(tokens.firstIndex(of: video ? 154832 : 154830))
        let end = try #require(tokens.lastIndex(of: video ? 154833 : 154831))
        return (end - begin + 1, output.placements.count)
    }
}

@Suite("GLM5Next media reservation from geometry")
struct GLM5NextMediaReservationTests {
    /// Prompt text the generic estimate counts: "Answer briefly." and "Which color?" at 3 bytes a token.
    let textTokens = 15 / 3 + 12 / 3

    @Test func aSevenTwentyPImageReservesItsOwnFrameNotAFullSizeOne() async throws {
        let vision = try visionConfiguration()
        let uri = try pngDataURI(width: 1280, height: 720)
        let image = request([.imageURL(uri)])
        let priced = try await quote(image)
        // A 1288 x 728 canvas: 92 x 52 = 4,784 patches, 1,196 features.
        let tower = GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision, patches: 4784)
        #expect(tower < 1 << 30)
        #expect(GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision) > 4 << 30)
        #expect(priced.kvTokens == textTokens + 1196 + 2 + 65_536)
        let decode = UInt64(1280 * 720 * 4 * MediaIngest.decodeOverheadFactor)
        let prepared = UInt64(4784 * 6 * 14 * 14 * 4)
        let features = UInt64(1198 * 4096 * 4)
        #expect(priced.bytes == (try encodedBytes(uri)) + decode + 3 * prepared + tower + features)
        // 0.10.13 charged a full 32,000-patch frame and 8,002 tokens.
        let before = try ceiling(image)
        #expect(before.kvTokens == textTokens + 8002 + 65_536)
        #expect(before.bytes > 4 << 30)
        #expect(priced.bytes < 1 << 30)
        // What the processor renders: begin, 1,196 features, end.
        #expect(try await rendered(image).tokens == 1198)
        // Either display orientation prices the same canvas.
        let portrait = try await quote(request([.imageURL(try pngDataURI(width: 720, height: 1280))]))
        #expect(portrait == priced)
    }

    @Test func anImageAtTheTokenCapStillPricesAFullSizeFrame() async throws {
        let vision = try visionConfiguration()
        let image = request([.imageURL(try pngDataURI(width: 4000, height: 3000))])
        let priced = try await quote(image)
        let plan = try GLM5NextMediaGeometry.resizePlan(width: 4000, height: 3000)
        let patches = plan.grid.height * plan.grid.width
        #expect(patches > 31_000 && patches <= GLM5NextVisionBudget.maximumFramePatches)
        #expect(priced.kvTokens == textTokens + patches / 4 + 2 + 65_536)
        #expect(
            priced.bytes >= GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision, patches: patches))
    }

    /// #928's condenser sends K keyframes as a 1 FPS MP4. GLM samples at
    /// 2 FPS, so the deduplicated sample is the K frames: K/2 frame pairs.
    @Test func aCondensedEightFrameClipIsPricedFromItsContainerNotTheCeiling() async throws {
        let vision = try visionConfiguration()
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 8, fps: 1, width: 1280, height: 720)
        let clip = request([.videoURL("data:video/mp4;base64," + mp4.base64EncodedString())])
        let priced = try await quote(clip)
        let processed = try await rendered(clip)
        #expect(processed.spans == 4)
        #expect(processed.tokens == 4 * 1196 + 4 * (2 + "0.0 seconds".utf8.count) + 2)
        // 8 s plus one of slack at 2 FPS: up to 18 frames, 9 pairs of 1,196.
        let tokens = 9 * 1196 + 9 * (2 + "9.0 seconds".utf8.count) + 2
        #expect(priced.kvTokens == textTokens + tokens + 65_536)
        #expect(tokens >= processed.tokens)
        let ceilingTokens = GLM5NextVisionBudget.videoTokenCeiling(processor: try GLM5NextProcessorConfiguration())
        #expect(ceilingTokens == 37_564)
        let tower = GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision, patches: 4784)
        let pixels: UInt64 = 1280 * 720
        let kept: UInt64 = 2 * 18 * pixels * 3
        let transient = UInt64(GLM5NextVisionBudget.videoDecodeTransientFrames) * pixels * 4
        let prepared: UInt64 = 9 * 4784 * 6 * 14 * 14 * 4
        let features = UInt64(tokens) * 4096 * 4
        let encoded = UInt64(mp4.count)
        #expect(priced.bytes == encoded + kept + transient + 3 * prepared + tower + features)
        // 0.10.13: the generic 384-megapixel video decode, the caps and the ceiling.
        let before = try ceiling(clip)
        #expect(before.bytes > 10 << 30)
        #expect(before.kvTokens == textTokens + ceilingTokens + 65_536)
        #expect(priced.bytes < 2 << 30)
    }

    /// A 1080p source condensed to 16 keyframes renders 8 pairs of 2,691
    /// features. Up to 34 frames fit the duration, but from 22 on the
    /// features pass the 28,532-feature prepared cap, a count the processor
    /// refuses before any tower work: the quote stops at 20 frames.
    @Test func aCondensedSixteenFrame1080pClipIsPricedBelowThePreparedCap() async throws {
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 16, fps: 1, width: 1920, height: 1080)
        let clip = request([.videoURL("data:video/mp4;base64," + mp4.base64EncodedString())])
        let priced = try await quote(clip)
        let rendered = 8 * 2691 + 8 * (2 + "14.0 seconds".utf8.count) + 2
        let tokens = 10 * 2691 + 10 * (2 + "17.0 seconds".utf8.count) + 2
        #expect(tokens >= rendered)
        #expect(priced.kvTokens == textTokens + tokens + 65_536)
        let before = try ceiling(clip)
        #expect(priced.kvTokens < before.kvTokens)
        // A 10,764-patch frame's tower and 10 pairs' prepared patches; 0.10.13 charged over 11 GiB.
        #expect(priced.bytes < 5 << 30 && before.bytes > 11 << 30)
        let shapes = try #require(await GLM5NextMediaShapes.probe(clip))
        let pixels = UInt64(try #require(shapes.videos.first?.sizes.map { $0.width * $0.height }.max()))
        let kept: UInt64 = 2 * 34 * pixels * 3
        let transient = UInt64(GLM5NextVisionBudget.videoDecodeTransientFrames) * pixels * 4
        let prepared: UInt64 = 10 * 10_764 * 6 * 14 * 14 * 4
        let tower = GLM5NextVisionBudget.towerWorkingSetBytes(configuration: try visionConfiguration(), patches: 10_764)
        #expect(
            priced.bytes
                == UInt64(mp4.count) + kept + transient + 3 * prepared + tower + UInt64(tokens) * 4096 * 4)
    }

    /// A track whose display matrix scales its frames renders them larger
    /// than any size the container states (`preferredTransform`), so only a
    /// matrix that turns or flips by quarter turns at unit scale is priced.
    @Test func aScaledTrackMatrixKeepsTheCeiling() async throws {
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 8, fps: 1, width: 128, height: 128)
        let plain = request([videoPart(mp4)])
        #expect(try await quote(plain) != (try ceiling(plain)))
        let scaled = request([videoPart(try withTrackMatrix(mp4, a: 16 * one, b: 0, c: 0, d: 16 * one))])
        #expect(try await quote(scaled) == (try ceiling(scaled)))
        let sheared = request([videoPart(try withTrackMatrix(mp4, a: one, b: one / 2, c: 0, d: one))])
        #expect(try await quote(sheared) == (try ceiling(sheared)))
    }

    @Test func aQuarterTurnedClipIsPricedAsItRenders() async throws {
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 8, fps: 1, width: 1280, height: 720)
        let upright = try await quote(request([videoPart(mp4)]))
        let turned = request([videoPart(try withTrackMatrix(mp4, a: 0, b: one, c: -one, d: 0))])
        #expect(try await quote(turned) == upright)
        let processed = try await rendered(turned)
        #expect(processed.spans == 4)
        #expect(upright.kvTokens - textTokens - 65_536 >= processed.tokens)
        for (a, b, c, d) in [(-one, 0, 0, -one), (-one, 0, 0, one), (0, -one, one, 0)] {
            let flipped = request([videoPart(try withTrackMatrix(mp4, a: a, b: b, c: c, d: d))])
            #expect(try await quote(flipped) == upright)
        }
    }

    @Test func displayMatricesAreReadFromTheContainer() async throws {
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 2, fps: 2, width: 64, height: 64)
        #expect(ISOBMFFDisplayMatrices.onlyQuarterTurns(mp4))
        #expect(ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: 0, b: one, c: -one, d: 0)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: 2 * one, b: 0, c: 0, d: 2 * one)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: one / 2, b: 0, c: 0, d: one)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(Data()))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(Data(repeating: 0xFF, count: 64)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(mp4.prefix(mp4.count / 2)))
    }

    /// Two images and a clip: every item's tokens and every encoded payload,
    /// the decode of the images and of the clip, and one prepared total.
    @Test func imagesAndAVideoAreEachPriced() async throws {
        let vision = try visionConfiguration()
        let wide = try pngDataURI(width: 1280, height: 720)
        let small = try pngDataURI(width: 640, height: 480)
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 8, fps: 1, width: 1280, height: 720)
        let mixed = request([.imageURL(wide), .imageURL(small), videoPart(mp4)])
        let priced = try await quote(mixed)
        let smallPlan = try GLM5NextMediaGeometry.resizePlan(width: 640, height: 480)
        let smallPatches = smallPlan.grid.height * smallPlan.grid.width
        let clipTokens = 9 * 1196 + 9 * (2 + "9.0 seconds".utf8.count) + 2
        let tokens = 1198 + (smallPatches / 4 + 2) + clipTokens
        #expect(priced.kvTokens == textTokens + tokens + 65_536)
        let pixels: UInt64 = 1280 * 720
        let decode = (pixels + 640 * 480) * 16 + 2 * 18 * pixels * 3
            + UInt64(GLM5NextVisionBudget.videoDecodeTransientFrames) * pixels * 4
        let encoded = try encodedBytes(wide) + encodedBytes(small) + UInt64(mp4.count)
        let prepared = UInt64(4784 + smallPatches + 9 * 4784) * 6 * 14 * 14 * 4
        let tower = GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision, patches: 4784)
        #expect(priced.bytes == encoded + decode + 3 * prepared + tower + UInt64(tokens) * 4096 * 4)
    }

    @Test func aClipOfManyCodedSizesOrAnotherSamplingKeepsTheCeiling() throws {
        let processor = try GLM5NextProcessorConfiguration()
        let sizes = (0..<5).map { GLM5NextMediaShapes.Size(width: 640 + 16 * $0, height: 360) }
        let same = Array(repeating: GLM5NextMediaShapes.Size(width: 640, height: 360), count: 5)
        let many = GLM5NextMediaShapes.Video(sizes: sizes, durationSeconds: 8, encodedBytes: 1)
        #expect(GLM5NextMediaQuote.video(many, processor: processor) == nil)
        #expect(GLM5NextMediaQuote.video(.init(sizes: same, durationSeconds: 8, encodedBytes: 1), processor: processor) != nil)
        #expect(GLM5NextMediaQuote.video(.init(sizes: Array(sizes.prefix(4)), durationSeconds: 8, encodedBytes: 1),
            processor: processor) != nil)
        let everyFrame = try GLM5NextProcessorConfiguration(videoSamplingPolicy: .disabled)
        #expect(GLM5NextMediaQuote.video(.init(sizes: same, durationSeconds: 8, encodedBytes: 1),
            processor: everyFrame) == nil)
    }

    @Test func anAudioPartKeepsTheCeilingAndNoContextLeavesTokensUnclamped() async throws {
        let uri = try pngDataURI(width: 1280, height: 720)
        let withAudio = request([.imageURL(uri), .inputAudio(.init(data: "AAAA", format: .wav))])
        #expect(try await quote(withAudio) == (try ceiling(withAudio)))
        let image = request([.imageURL(uri)])
        let unclamped = try await GLM5NextVisionBudget.mediaReservation(
            request: image, vision: visionConfiguration(), processor: GLM5NextProcessorConfiguration(),
            defaultMaxTokens: 64, contextLength: 0, generic: generic(image), environment: [:])
        #expect(unclamped.kvTokens == textTokens + 1198 + 65_536)
    }

    @Test func theReadinessClipQuoteCoversWhatTheProcessorRenders() async throws {
        let clip = request([.videoURL("data:video/mp4;base64," + (try readinessClip()).base64EncodedString())])
        let priced = try await quote(clip)
        let processed = try await rendered(clip)
        #expect(processed.spans == 5)
        #expect(priced.kvTokens - textTokens - 65_536 >= processed.tokens)
        #expect(priced.kvTokens < (try ceiling(clip)).kvTokens)
    }

    @Test func mediaWhoseGeometryCanNotBeReadKeepsTheCeiling() async throws {
        for part: OpenAIContentPart in [
            .imageURL("data:image/png;base64,AAAA"), .imageURL("https://example.com/a.png"),
            .videoURL("data:video/mp4;base64,AAAA"),
        ] {
            let unreadable = request([.imageURL(try pngDataURI(width: 64, height: 64)), part])
            #expect(try await quote(unreadable) == (try ceiling(unreadable)))
        }
    }

    @Test(arguments: ["0", " OFF ", "false", "No"])
    func theSwitchRestoresTheCeiling(_ value: String) async throws {
        let image = request([.imageURL(try pngDataURI(width: 1280, height: 720))])
        let environment = [GLM5NextVisionBudget.geometryEnvironmentKey: value]
        #expect(!GLM5NextVisionBudget.pricesGeometry(environment: environment))
        #expect(try await quote(image, environment: environment) == (try ceiling(image)))
    }

    @Test func theSwitchIsOnByDefaultAndReachesTheProviderJob() {
        #expect(GLM5NextVisionBudget.pricesGeometry(environment: [:]))
        #expect(GLM5NextVisionBudget.pricesGeometry(environment: [GLM5NextVisionBudget.geometryEnvironmentKey: "1"]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GLM5NextVisionBudget.geometryEnvironmentKey))
    }

    /// The media gate on a Mac with 6 GiB of headroom left beside a grown
    /// GLM pool: the 720p image's ceiling (~7.3 GiB) is refused as
    /// `media_memory_unavailable`; its own price (~2.9 GiB) is admitted.
    @Test func theMediaGateAdmitsWhatOnlyTheCeilingRefused() async throws {
        let image = request([.imageURL(try pngDataURI(width: 1280, height: 720))])
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(
                total: UnifiedMemoryCap.minimumReserveBytes + 6 << 30, active: 0, cache: 0,
                systemAvailable: .max)
        }
        let gate = VisionMemoryGate(kvBudget: budget, fp16KVBytesPerToken: 33_836, contextLength: contextLength)
        let before = try ceiling(image)
        #expect(!(await gate.reserve(
            requestId: "ceiling", mediaDecodeBytes: before.bytes, kvTokens: before.kvTokens)))
        let priced = try await quote(image)
        #expect(await gate.reserve(
            requestId: "priced", mediaDecodeBytes: priced.bytes, kvTokens: priced.kvTokens))
        await gate.release(requestId: "priced")
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
