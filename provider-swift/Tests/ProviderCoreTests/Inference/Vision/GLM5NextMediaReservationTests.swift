// Copyright © 2026 Eigen Labs.
//
// GLM-5.3-Flash's media memory reservation priced from each image's header
// and each video's container: the quote against the real GLM processor's
// rendering, the processor's ceilings when geometry can't be read or the
// switch is off, and the media gate's decision either way. Then a long clip
// shrunk to the prepared-pixel cap instead of refused. No model weights.

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

/// `movie` with its track header's display matrix set to `a b / c d` and
/// offset `x, y` (16.16 fixed point), without perspective. The header is the
/// first `tkhd` after `moov`, which AVAssetWriter writes after `mdat`.
private func withTrackMatrix(
    _ movie: Data, a: Int32, b: Int32, c: Int32, d: Int32, x: Int32 = 0, y: Int32 = 0
) throws -> Data {
    var data = movie
    let moov = try #require(data.range(of: Data("moov".utf8), options: .backwards))
    let type = try #require(data.range(of: Data("tkhd".utf8), in: moov.upperBound ..< data.endIndex))
    let content = type.upperBound - data.startIndex
    let version = data[data.startIndex + content]
    let matrix = content + 4 + (version == 1 ? 32 : 20) + 16
    for (index, value) in [a, b, 0, c, d, 0, x, y, 0x4000_0000].enumerated() {
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

private let fixed = GLM5NextVisionBudget.fixedWorkingBytes

/// The scheduler's generic projection for `request`.
private func generic(_ request: OpenAIChatCompletionRequest) -> GLM5NextVisionBudget.Reservation {
    .init(
        bytes: MediaIngest.projectedDecodeBytes(request),
        kvTokens: MediaIngest.projectedKVTokens(request, defaultMaxTokens: 64, contextLength: contextLength))
}

private func quote(
    _ request: OpenAIChatCompletionRequest, environment: [String: String] = [:],
    processor: GLM5NextProcessorConfiguration? = nil
) async throws -> GLM5NextVisionBudget.Reservation {
    try await GLM5NextVisionBudget.mediaReservation(
        request: request, vision: visionConfiguration(), processor: processor ?? GLM5NextProcessorConfiguration(),
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
/// video, from its begin token to its end token, its placement count, its
/// features, its grids and, when asked, its prepared pixels.
private func rendered(
    _ request: OpenAIChatCompletionRequest, processor configuration: GLM5NextProcessorConfiguration? = nil,
    pixels: Bool = false
) async throws -> (tokens: Int, spans: Int, features: Int, grids: [[Int]], pixels: [Float]) {
    let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: .init())
    let processor = try GLM5NextProcessor(
        configuration: configuration ?? .init(), tokenizer: GLMRenderTokenizer())
    return try await Device.withDefaultDevice(.cpu) {
        let output = try await processor.prepareDetailed(input: input)
        let tokens = output.input.text.tokens.asType(.int64).asArray(Int64.self).map(Int.init)
        let video = output.input.video != nil
        let begin = try #require(tokens.firstIndex(of: video ? 154832 : 154830))
        let end = try #require(tokens.lastIndex(of: video ? 154833 : 154831))
        let features = output.placements.reduce(0) { $0 + $1.featureRange.count }
        let media = output.input.video.map { ($0.pixels, $0.frames) } ?? output.input.image.map { ($0.pixels, $0.frames) }
        let grids = (media?.1 ?? []).map { [$0.t, $0.h, $0.w] }
        let values = pixels ? (media?.0.asArray(Float.self) ?? []) : []
        return (end - begin + 1, output.placements.count, features, grids, values)
    }
}

@Suite("GLM5Next media reservation from geometry")
struct GLM5NextMediaReservationTests {
    /// Prompt text the estimate counts: "Answer briefly." and "Which color?" at 3 bytes a token, and the
    /// chat template's allowance for a request of two messages.
    let textTokens = 15 / 3 + 12 / 3 + GLM5NextVisionBudget.templateTokens + 2 * GLM5NextVisionBudget.templateTokensPerMessage
    /// The same text at the generic estimate, as 0.10.13's charge counts it.
    let genericTextTokens = 15 / 3 + 12 / 3

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
        #expect(priced.bytes == (try encodedBytes(uri)) + decode + 3 * prepared + tower + fixed + features)
        // 0.10.13 charged a full 32,000-patch frame and 8,002 tokens.
        let before = try ceiling(image)
        #expect(before.kvTokens == genericTextTokens + 8002 + 65_536)
        #expect(before.bytes > 4 << 30)
        #expect(priced.bytes < 1 << 30)
        // What the processor renders: begin, 1,196 features, end.
        #expect(try await rendered(image).tokens == 1198)
        // Either display orientation prices the same canvas.
        let portraitURI = try pngDataURI(width: 720, height: 1280)
        let portrait = try await quote(request([.imageURL(portraitURI)]))
        #expect(portrait.kvTokens == priced.kvTokens)
        #expect(portrait.bytes - (try encodedBytes(portraitURI)) == priced.bytes - (try encodedBytes(uri)))
    }

    /// Measured on GLM-5.3-Flash (NVFP4, M5 Ultra, MEDIA-14 window 2): a
    /// 256 x 256 image's preparation peaked 78.7 MB of MLX memory over its
    /// start, while its per-patch terms price 400 patches at ~68 MB. The tower
    /// has a fixed working part that no patch term covers.
    @Test func aSmallImageCoversTheTowersFixedWorkingMemory() async throws {
        let priced = try await quote(request([.imageURL(try pngDataURI(width: 256, height: 256))]))
        #expect(priced.bytes >= 2 * 78_726_723)
    }

    /// GLM's prompt is more than its text: the chat template (measured: a
    /// one-turn image request renders 7 tokens more than the text estimate)
    /// and every declared tool's schema. Neither may be left out of the KV.
    @Test func theTemplateAndToolsAreInTheTokens() async throws {
        let image = try pngDataURI(width: 1280, height: 720)
        let plain = try await quote(request([.imageURL(image)]))
        // Real prompt tokens at the GLM processor, window 2: 1,219 for this request.
        #expect(plain.kvTokens >= 1219 + 65_536)
        var withTools = request([.imageURL(image)])
        let schema = String(repeating: "x", count: 3000)
        withTools.tools = [
            OpenAITool(type: "function", function: .init(name: "lookup", description: schema, parameters: nil))
        ]
        let tooled = try await quote(withTools)
        #expect(tooled.kvTokens >= plain.kvTokens + 1000)
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
        #expect(priced.bytes == encoded + kept + transient + 3 * prepared + tower + fixed + features)
        // 0.10.13: the generic 384-megapixel video decode, the caps and the ceiling.
        let before = try ceiling(clip)
        #expect(before.bytes > 10 << 30)
        #expect(before.kvTokens == genericTextTokens + ceilingTokens + 65_536)
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
                == UInt64(mp4.count) + kept + transient + 3 * prepared + tower + fixed + UInt64(tokens) * 4096 * 4)
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
        // Whole-pixel offsets move the frame; a fractional one renders one more
        // row and column than the stated size.
        #expect(ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: 0, b: one, c: -one, d: 0, x: 64 * one)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: one, b: 0, c: 0, d: one, x: one / 2)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: one, b: 0, c: 0, d: one, y: 1)))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: one, b: 0, c: 0, d: one, x: -one / 2)))
        #expect(ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mp4, a: -one, b: 0, c: 0, d: one, x: -64 * one)))
        // QuickTime; two movie boxes; a track without a header.
        let mov = try await NemotronSuperVideoClips.movie(frames: 2, fps: 2, width: 64, height: 64, fileType: .mov)
        #expect(ISOBMFFDisplayMatrices.onlyQuarterTurns(mov))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(try withTrackMatrix(mov, a: 4 * one, b: 0, c: 0, d: 4 * one)))
        let moov = try #require(mp4.range(of: Data("moov".utf8), options: .backwards))
        let moovBox = mp4[(moov.lowerBound - 4)...]
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(mp4 + moovBox))
        var headless = mp4
        let header = try #require(headless.range(of: Data("tkhd".utf8), in: moov.upperBound ..< headless.endIndex))
        headless.replaceSubrange(header, with: Data("free".utf8))
        #expect(!ISOBMFFDisplayMatrices.onlyQuarterTurns(headless))
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
        #expect(priced.bytes == encoded + decode + 3 * prepared + tower + fixed + UInt64(tokens) * 4096 * 4)
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

/// The published artifact's processor_config.json: the cluster fixture's
/// contract (images up to 8,000 tokens, videos up to 240,000 at 2 FPS) at
/// patch 14.
private func publishedProcessorConfiguration() throws -> Data {
    var processor = try #require(
        JSONSerialization.jsonObject(with: GLMClusterTensorParallelMediaTests.processorConfiguration())
            as? [String: Any])
    for key in ["image_processor", "video_processor"] {
        var media = try #require(processor[key] as? [String: Any])
        media["patch_size"] = 14
        processor[key] = media
    }
    return try JSONSerialization.data(withJSONObject: processor)
}

/// The GLM fixture's model configuration at the published vision patch (14).
private func patchFourteenConfiguration() throws -> GLM5NextConfiguration {
    var config = try #require(
        JSONSerialization.jsonObject(with: GLMClusterTensorParallelMediaTests.configuration()) as? [String: Any])
    var vision = try #require(config["vision_config"] as? [String: Any])
    vision["patch_size"] = 14
    vision["image_size"] = 28
    config["vision_config"] = vision
    return try JSONDecoder().decode(
        GLM5NextConfiguration.self, from: JSONSerialization.data(withJSONObject: config))
}

/// The processor budgets a GLM Mac loads (`GLM5NextArtifactPlan`) and a GLM
/// pair's leader binds (`DistributedGLMMediaIngress`) from the published
/// artifact.
private func productProcessors(environment: [String: String] = [:]) throws -> [GLM5NextProcessorConfiguration] {
    let data = try publishedProcessorConfiguration()
    let configuration = try patchFourteenConfiguration()
    return [
        try GLM5NextArtifactPlan.processorConfiguration(data, configuration: configuration, environment: environment),
        try DistributedGLMMediaIngress.processorConfiguration(
            data, configuration: configuration, environment: environment),
    ]
}

/// `body` fails as the processor refuses a plan past its prepared-pixel cap.
private func expectPreparedPixelRefusal(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected the prepared-pixel refusal")
    } catch {
        #expect(error as? GLM5NextVisionError == .budgetExceeded("prepared pixels"))
    }
}

@Suite("GLM5Next long videos fitted to the prepared-pixel cap")
struct GLM5NextLongVideoFitTests {
    let textTokens = 15 / 3 + 12 / 3 + GLM5NextVisionBudget.templateTokens + 2 * GLM5NextVisionBudget.templateTokensPerMessage

    /// 28,532 features' FP32 patches fill the processor's 512 MiB prepared-
    /// pixel cap; the artifact's 240,000-token video budget never binds first.
    @Test func bothProductContractsLimitVideoToThePreparedCap() throws {
        for processor in try productProcessors() {
            #expect(processor.videoMaximumTokens == 28_532)
            #expect(processor.videoMinimumTokens == 16)
            #expect(processor.imageMaximumTokens == 8000 && processor.imageMinimumTokens == 16)
            #expect(processor.maximumPreparedBytes == 512 << 20 && processor.videoSamplingPolicy == .official)
            #expect(GLM5NextVisionBudget.maximumPreparedFeatures(processor: processor) == 28_532)
        }
    }

    /// The processor plans a clip's frames with `resizePlan` under its video
    /// budget and refuses a plan whose FP32 patches pass the prepared cap.
    /// 26 s of 720p at 2 FPS keeps 52 frames: under the artifact's budget,
    /// 26 pairs at 1288 x 728, 31,096 features, past the cap (a 400); under
    /// the product's, 26 pairs at 1204 x 700, 27,950 features, within it.
    @Test func aLongSevenTwentyPClipIsPlannedWithinTheCap() throws {
        let patchBytes = 3 * 2 * 14 * 14 * 4
        let own = try GLM5NextMediaGeometry.resizePlan(
            width: 1280, height: 720, frames: 52, patchSize: 14, minimumTokens: 16, maximumTokens: 240_000)
        #expect(own.width == 1288 && own.height == 728)
        #expect(try own.grid.featureCount() == 31_096)
        #expect(try own.grid.patchCount() * patchBytes > 512 << 20)
        for processor in try productProcessors() {
            let fitted = try GLM5NextMediaGeometry.resizePlan(
                width: 1280, height: 720, frames: 52, patchSize: 14,
                minimumTokens: processor.videoMinimumTokens, maximumTokens: processor.videoMaximumTokens)
            #expect(fitted.width == 1204 && fitted.height == 700)
            #expect(fitted.grid.temporal == 26)
            #expect(try fitted.grid.featureCount() == 26 * 1075)
            #expect(try fitted.grid.patchCount() * patchBytes <= 512 << 20)
        }
    }

    /// Over frame sizes from 1 x 1 to 65536 x 8 (both orientations) and every
    /// 2 FPS frame count, the cap's budget plans every clip the artifact's
    /// budget kept within the cap identically, and every other clip within it.
    @Test func theCapsBudgetChangesOnlyClipsPastTheCap() throws {
        let cap = GLM5NextVisionBudget.maximumPreparedFeatures(processor: try GLM5NextProcessorConfiguration())
        let sizes = [
            (1, 1), (14, 14), (28, 28), (64, 64), (320, 180), (640, 360), (854, 480), (1080, 1080),
            (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (4096, 2160), (7680, 4320), (65536, 8),
            (1, 4096), (333, 777), (1003, 557),
        ]
        var kept = 0
        var shrunk = 0
        for (width, height) in sizes {
            for (w, h) in [(width, height), (height, width)] {
                for frames in stride(from: 2, through: 2048, by: 2) {
                    let own = try GLM5NextMediaGeometry.resizePlan(
                        width: w, height: h, frames: frames, patchSize: 14, minimumTokens: 16, maximumTokens: 240_000)
                    let fitted = try GLM5NextMediaGeometry.resizePlan(
                        width: w, height: h, frames: frames, patchSize: 14, minimumTokens: 16, maximumTokens: cap)
                    #expect(try fitted.grid.featureCount() <= cap)
                    if try own.grid.featureCount() <= cap {
                        kept += 1
                        #expect(
                            fitted.width == own.width && fitted.height == own.height
                                && fitted.contentWidth == own.contentWidth && fitted.contentHeight == own.contentHeight
                                && fitted.grid.temporal == own.grid.temporal && fitted.grid.height == own.grid.height
                                && fitted.grid.width == own.grid.width)
                    } else {
                        shrunk += 1
                    }
                }
            }
        }
        #expect(kept > 0 && shrunk > 0)
    }

    /// The real processor end to end, with an 8 MiB prepared cap (445
    /// features) so the render stays small: 10 s of 320 x 180 at 2 FPS keeps
    /// 20 frames, 10 pairs of 84 features, 840 in all. The processor's own
    /// budget refuses it; the fitted budget renders 10 pairs at 224 x 140
    /// (40 features each), and the media quote covers what renders.
    @Test func aLongClipShrinksToFitInsteadOfBeingRefused() async throws {
        let own = try GLM5NextProcessorConfiguration(maximumPreparedBytes: 8 << 20)
        let fitted = try GLM5NextVisionBudget.fittingLongVideos(own, environment: [:])
        #expect(fitted.videoMaximumTokens == 445)
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 20, fps: 2, width: 320, height: 180)
        let clip = request([videoPart(mp4)])
        await expectPreparedPixelRefusal { _ = try await rendered(clip, processor: own) }
        let processed = try await rendered(clip, processor: fitted)
        #expect(processed.spans == 10 && processed.features == 10 * 40 && processed.grids == [[10, 10, 16]])
        let priced = try await quote(clip, processor: fitted)
        #expect(priced.kvTokens - textTokens - 65_536 >= processed.tokens)
        #expect(priced.kvTokens - textTokens - 65_536 <= GLM5NextVisionBudget.videoTokenCeiling(processor: fitted))
    }

    /// A clip within the cap renders and is priced exactly as before.
    @Test func aClipWithinTheCapRendersAsBefore() async throws {
        let own = try GLM5NextProcessorConfiguration(maximumPreparedBytes: 8 << 20)
        let fitted = try GLM5NextVisionBudget.fittingLongVideos(own, environment: [:])
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 8, fps: 2, width: 320, height: 180)
        let clip = request([videoPart(mp4)])
        let before = try await rendered(clip, processor: own, pixels: true)
        #expect(before.features == 4 * 84 && before.grids == [[4, 14, 24]])
        let after = try await rendered(clip, processor: fitted, pixels: true)
        #expect(after.tokens == before.tokens && after.grids == before.grids)
        #expect(after.pixels == before.pixels)
        #expect(try await quote(clip, processor: fitted) == (try await quote(clip, processor: own)))
    }

    @Test(arguments: ["0", " OFF ", "false", "No"])
    func theSwitchKeepsTheArtifactsBudgetAndTheRefusal(_ value: String) async throws {
        let environment = [GLM5NextVisionBudget.longVideoFitEnvironmentKey: value]
        #expect(!GLM5NextVisionBudget.fitsLongVideos(environment: environment))
        #expect(try GLM5NextVisionBudget.fittingLongVideos(.init(), environment: environment).videoMaximumTokens
            == 240_000)
        let kept = try GLM5NextVisionBudget.fittingLongVideos(
            .init(maximumPreparedBytes: 8 << 20), environment: environment)
        #expect(kept.videoMaximumTokens == 240_000)
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 20, fps: 2, width: 320, height: 180)
        await expectPreparedPixelRefusal { _ = try await rendered(request([videoPart(mp4)]), processor: kept) }
        for processor in try productProcessors(environment: environment) {
            #expect(processor.videoMaximumTokens == 240_000)
        }
    }

    @Test func theSwitchIsOnByDefaultAndReachesTheProviderJob() throws {
        let key = GLM5NextVisionBudget.longVideoFitEnvironmentKey
        #expect(GLM5NextVisionBudget.fitsLongVideos(environment: [:]))
        #expect(GLM5NextVisionBudget.fitsLongVideos(environment: [key: "1"]))
        #expect(try GLM5NextVisionBudget.fittingLongVideos(.init(), environment: [:]).videoMaximumTokens == 28_532)
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
    }

    /// A budget already within the cap (the fixtures' patch-2 artifacts:
    /// 1,398,101 features fit 512 MiB) is kept as it is.
    @Test func aBudgetWithinTheCapIsKept() throws {
        let small = try GLM5NextProcessorConfiguration(patchSize: 2, videoMaximumTokens: 240_000)
        #expect(try GLM5NextVisionBudget.fittingLongVideos(small, environment: [:]).videoMaximumTokens == 240_000)
    }
}

/// `glm5FrameLimits` on `grid`'s one frame: "plans"; "400" for
/// `unsupportedMedia`, which the scheduler answers as the request's fault;
/// "503" for `towerBudgetExceeded`, the retriable construction refusal;
/// anything else as itself.
private func frameOutcome(_ grid: GLM5NextVisionGrid, operatorMaxPatches: Int? = nil) throws -> String {
    let configuration = try visionConfiguration()
    let limits = VisionTowerBudget.Limits(
        maxBufferBytes: 1 << 40, attentionElementBytes: 4, headFactor: 1, operatorMaxPatches: operatorMaxPatches)
    do {
        _ = try VisionTowerBudget.glm5FrameLimits(
            grid: THW(1, grid.height, grid.width), configuration: configuration, limits: limits)
        return "plans"
    } catch let error as EngineV2VisionPrefillError {
        switch error {
        case .unsupportedMedia where EngineV2VisionPrefill.clientFault(for: error) != nil: return "400"
        case .towerBudgetExceeded where EngineV2VisionPrefill.clientFault(for: error) == nil: return "503"
        default: return String(describing: error)
        }
    }
}

@Suite("GLM5Next frames past the native tower limit")
struct GLM5NextFrameLimitTests {
    /// GLM's tower takes at most 32,000 patches a frame pair on every Mac. A
    /// 4K clip of one or a few pairs passes it: 2 frames render 156 x 276 =
    /// 43,056 patches, and 6 frames, shrunk to the prepared cap, 3 pairs of
    /// 146 x 260 = 37,960. Every provider refuses those, so the refusal is the
    /// request's fault, a 400 the coordinator does not retry elsewhere.
    @Test func aFramePastTheNativeLimitIsTheRequestsFault() throws {
        for frames in [2, 6] {
            let plan = try GLM5NextMediaGeometry.resizePlan(
                width: 3840, height: 2160, frames: frames, patchSize: 14, minimumTokens: 16, maximumTokens: 28_532)
            #expect(plan.grid.height * plan.grid.width > GLM5NextVisionBudget.maximumFramePatches)
            #expect(try frameOutcome(plan.grid) == "400")
        }
        #expect(try frameOutcome(.init(temporal: 1, height: 160, width: 202)) == "400")
    }

    /// An operator's lower limit (`DARKBLOOM_VISION_MAX_TOWER_PATCHES`) is
    /// this Mac's own: another can serve the frame, so it stays retriable.
    /// Within both limits the frame plans.
    @Test func anOperatorsLowerLimitStaysRetriable() throws {
        let frame = try GLM5NextVisionGrid(temporal: 1, height: 100, width: 200)
        #expect(try frameOutcome(frame, operatorMaxPatches: 16_000) == "503")
        #expect(try frameOutcome(frame) == "plans")
        #expect(try frameOutcome(.init(temporal: 1, height: 160, width: 200)) == "plans")
    }
}

/// The timestamp text after each frame pair `request`'s video renders, as
/// the real GLM processor configured by `configuration` renders it.
private func pairTimestamps(
    _ request: OpenAIChatCompletionRequest, processor configuration: GLM5NextProcessorConfiguration
) async throws -> [String] {
    let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: .init())
    let processor = try GLM5NextProcessor(configuration: configuration, tokenizer: GLMRenderTokenizer())
    return try await Device.withDefaultDevice(.cpu) {
        let tokens = try await processor.prepareDetailed(input: input).input.text.tokens
            .asType(.int64).asArray(Int64.self).map(Int.init)
        return tokens.indices.filter { tokens[$0] == 154831 }.map { end in
            let text = tokens[(end + 1)...].prefix { $0 < 154830 }.compactMap { Unicode.Scalar($0) }
            return String(String.UnicodeScalarView(text))
        }
    }
}

@Suite("GLM5Next long clips sampled to the decoded-frame cap")
struct GLM5NextLongClipSamplingTests {
    let textTokens = 15 / 3 + 12 / 3 + GLM5NextVisionBudget.templateTokens + 2 * GLM5NextVisionBudget.templateTokensPerMessage

    /// A GLM Mac samples a clip past its 512 MiB decoded-frame cap (720p past
    /// about 97 s) down to the frames the cap holds. A pair's leader does not:
    /// rank 0 prepares the same bytes with the leader's wire budgets, which
    /// carry no sampling option, so it would sample differently.
    @Test func aMacSamplesLongClipsDownAndAPairsLeaderDoesNot() throws {
        let processors = try productProcessors()
        #expect(processors.map(\.fitsVideoSampleToDecodedBytes) == [true, false])
        let mac = try #require(processors.first)
        #expect(mac.maximumSampledVideoFrames(frameBytes: 1280 * 720 * 3) == 193)
        #expect(mac.maximumSampledVideoFrames(frameBytes: 1920 * 1080 * 3) == 85)
    }

    /// End to end with the Mac's sampling and a decoded-frame cap of 8
    /// frames of 320 x 180 (7 RGB8 frames and the last one's RGBA render):
    /// 10 s at 2 FPS keeps 20 frames, past the cap, so the processor refuses
    /// it without the sampling; with it, 8 frames spread over the clip render
    /// 4 pairs whose timestamps run to its end, and the media quote covers
    /// what renders.
    @Test func aClipPastTheDecodedCapIsServedAcrossIt() async throws {
        let mac = try #require(try productProcessors().first)
        let cap = 7 * 320 * 180 * 3 + 320 * 180 * 4
        let own = try GLM5NextProcessorConfiguration(maximumDecodedBytes: cap)
        let sampled = try GLM5NextProcessorConfiguration(
            maximumDecodedBytes: cap, fitsVideoSampleToDecodedBytes: mac.fitsVideoSampleToDecodedBytes)
        let mp4 = try await NemotronSuperVideoClips.movie(frames: 20, fps: 2, width: 320, height: 180)
        let clip = request([videoPart(mp4)])
        do {
            _ = try await rendered(clip, processor: own)
            Issue.record("expected the decoded-frame refusal")
        } catch {
            #expect(error as? GLM5NextVisionError == .budgetExceeded("decoded image"))
        }
        let processed = try await rendered(clip, processor: sampled)
        #expect(processed.spans == 4 && processed.grids == [[4, 14, 24]])
        #expect(try await pairTimestamps(clip, processor: sampled)
            == ["0.0 seconds", "2.5 seconds", "5.0 seconds", "8.0 seconds"])
        let priced = try await quote(clip, processor: sampled)
        #expect(priced.kvTokens - textTokens - 65_536 >= processed.tokens)
        // Bytes: both reader passes' kept frames at the cap and three copies of
        // the 4 pairs' prepared patches.
        let patches: UInt64 = 4 * 14 * 24
        let prepared: UInt64 = patches * 4704
        let kept = 2 * UInt64(cap)
        #expect(priced.bytes >= kept + 3 * prepared)
    }

    @Test(arguments: ["0", " OFF ", "false", "No"])
    func theSwitchKeepsTheFullSampleAndTheRefusal(_ value: String) throws {
        let environment = [GLM5NextVisionBudget.longVideoSamplingEnvironmentKey: value]
        #expect(!GLM5NextVisionBudget.samplesLongVideos(environment: environment))
        #expect(try productProcessors(environment: environment).map(\.fitsVideoSampleToDecodedBytes) == [false, false])
        // The long-video fit is its own switch.
        #expect(try productProcessors(environment: environment).map(\.videoMaximumTokens) == [28_532, 28_532])
    }

    @Test func theSwitchIsOnByDefaultAndReachesTheProviderJob() throws {
        let key = GLM5NextVisionBudget.longVideoSamplingEnvironmentKey
        #expect(GLM5NextVisionBudget.samplesLongVideos(environment: [:]))
        #expect(GLM5NextVisionBudget.samplesLongVideos(environment: [key: "1"]))
        let sampled = try GLM5NextVisionBudget.samplingLongVideos(.init(videoMaximumTokens: 28_532), environment: [:])
        #expect(sampled.fitsVideoSampleToDecodedBytes && sampled.videoMaximumTokens == 28_532)
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        // The long-video fit keeps the sampling when it rebuilds a configuration.
        let both = try GLM5NextVisionBudget.fittingLongVideos(
            .init(fitsVideoSampleToDecodedBytes: true), environment: [:])
        #expect(both.fitsVideoSampleToDecodedBytes && both.videoMaximumTokens == 28_532)
    }
}
