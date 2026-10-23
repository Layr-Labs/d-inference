// Copyright © 2026 Eigen Labs.
//
// GLM-5.3-Flash media routing and reservation: a scripted in-process engine,
// a real `ModelContainer` over stub model/processor/tokenizer and an injected
// preparer. No model weights. The native builder itself is exercised by
// `GLM5NextManagedLoadTests` on synthetic GLM weights.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXNN
import MLXVLM
import Testing

@testable import ProviderCore

private let pngDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

// A real, round-trip-verified 64x64 H.264 mp4 (3 solid-gray frames) — same
// fixture as MediaIngestTests.
private let tinyMP4DataURI =
    "data:video/mp4;base64,"
    + "AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAAK4AAAA7BgUyR1ZK3FxMQz+U78URPNFDqAEAAAMAAQMAAAMAAQIAAeYACwAAAwAA"
    + "AwAAAwAUDAOJJAEN/////4AAAAAxJbggH4AuSqwRNmYXSACJwyG5akafRwrPDoFqVCtjHBP+QvRWhyAAGk1PzfAEsEedgAAAABEh4QhfAoAvQrFXFN4ACQ7CtgA"
    + "AABEBqIGK/1jQw/VufW+ACvdnuAAAAvFtb292AAAAbG12aGQAAAAA5lOws+ZTsLMAAAJYAAACWAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAA"
    + "AAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACfXRyYWsAAABcdGtoZAAAAAHmU7Cz5lOwswAAAAEAAAAAAAACWAAAAAAAAAAA"
    + "AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAlgAAADIAAEAAAAAAfV"
    + "tZGlhAAAAIG1kaGQAAAAA5lOws+ZTsLMAAAJYAAACWFXEAAAAAAAxaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAENvcmUgTWVkaWEgVmlkZW8AAAABnG1pbm"
    + "YAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVxzdGJsAAAAoXN0c2QAAAAAAAAAAQAAAJFhdmMxAAAAAA"
    + "AAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAJ2F2Y0MBZAAL/+EADCdkAA"
    + "usVlDDeBBhFAEABCjuPLD9+PgAAAAACmZpZWwBAAAAAApjaHJtAAAAAAAYc3R0cwAAAAAAAAABAAAAAwAAAMgAAAAoY3R0cwAAAAAAAAADAAAAAQAAAMgAAAABAA"
    + "ABkAAAAAEAAAAAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAPc2R0cAAAAAAgEBgAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAMAAAABAAAAIHN0c3oAAAAAAAAAAAAAAA"
    + "MAAAB0AAAAFQAAABUAAAAUc3RjbwAAAAAAAAABAAAALA=="

private final class GLMScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CBv2Request] = []
    var submitted: [CBv2Request] { lock.withLock { recorded } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { recorded.append(request) }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.yield(.delta(text: "red", tokens: [5], logprobs: nil))
        continuation.yield(
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: 1)))
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct GLMStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 0, count: text.count) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map { "t\($0)" }.joined() }
    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [1, 2, 3] }
}

private final class GLMStubModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct GLMStubProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}

/// Media-token identities the GLM processor requires; renders symbolic media
/// parts as the shipped template does and text as one token per scalar.
private struct GLMMediaMarkerTokenizer: MLXLMCommon.Tokenizer {
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

/// OpenRouter's provider-readiness clips, kept as SDK test resources.
private func openRouterVideo(_ name: String, sha256: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent(
        "libs/mlx-swift-lm/Tests/MLXLMTests/Resources/MiMoOpenRouter/\(name)"))
    #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256)
    return data
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpenAIChatCompletionRequest] = []
    var requests: [OpenAIChatCompletionRequest] { lock.withLock { values } }
    func record(_ request: OpenAIChatCompletionRequest) { lock.withLock { values.append(request) } }
}

/// Each prepared video's grid rows followed by its placement span lengths.
private final class PreparedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[Int]] = []
    var values: [[Int]] { lock.withLock { recorded } }
    func record(_ values: [[Int]]) { lock.withLock { recorded = values } }
}

private func stubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/glm-stub"), model: GLMStubModel(),
            processor: GLMStubProcessor(), tokenizer: GLMStubTokenizer()))
}

private func router(
    bridge: EngineV2Bridge?, plumbing: EngineV2VisionPlumbing
) -> MultiModelBatchSchedulerEngine {
    MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in
            [
                "test/glm-stub": .init(
                    tokenizer: TokenizerHandle(GLMStubTokenizer()), modelType: "glm5_next",
                    container: stubContainer(), isVLM: true, engineV2Bridge: bridge)
            ]
        },
        defaultMaxTokens: 64, engineV2Vision: plumbing)
}

private func imageRequest(_ parts: [OpenAIContentPart]? = nil) -> OpenAIChatCompletionRequest {
    OpenAIChatCompletionRequest(
        model: "test/glm-stub",
        messages: [
            .init(role: .system, content: .text("Answer briefly.")),
            .init(role: .user, content: .parts(parts ?? [.text("Which color?"), .imageURL(pngDataURI)])),
        ],
        temperature: 0, maxTokens: 8)
}

private func preparedSubmission() -> EngineV2VisionPrefill.PreparedSubmission {
    .init(
        promptTokens: [1, 154854, 154854, 2], spans: [.init(tokenOffset: 1, length: 2)],
        embeddings: [MLXArray.zeros([1, 2, 4])], spanKinds: [.image], attention: .causal,
        positionState: nil, mediaKind: .image)
}

@Suite("GLM5Next media routing")
struct GLM5NextMediaRoutingTests {
    @Test func imageReachesTheEngineAsCausalPositionFreeSpansFromTheOriginalRequest() async throws {
        let engine = GLMScriptedEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "test/glm-stub", tokenizer: TokenizerHandle(GLMStubTokenizer()),
            eosTokenIds: [2], kvBytesPerToken: 0)
        #expect(await bridge.servesGLM5NextMedia)
        let capture = RequestCapture()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, request, _ in
                capture.record(request)
                return preparedSubmission()
            }, emitTelemetry: { _ in })
        let original = imageRequest()
        var content = ""
        for try await event in try await router(bridge: bridge, plumbing: plumbing)
            .streamChatCompletion(request: original)
        {
            if case .content(let text) = event { content += text }
        }
        #expect(content == "red")
        // GLM normalizes the caller's request itself, exactly as its text path
        // does; the generic VLM template fixes never pre-normalize it.
        #expect(capture.requests.map(\.messages) == [original.messages])
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.promptTokens == [1, 154854, 154854, 2])
        #expect(submitted.multimodal?.attention == .causal)
        #expect(submitted.multimodal?.positionState == nil && submitted.positionState == nil)
        #expect(submitted.multimodal?.spans == [.init(tokenOffset: 1, length: 2)])
    }

    @Test func slotWithoutAMediaCapableEngineRefusesBeforePreparation() async throws {
        let capture = RequestCapture()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, request, _ in
                capture.record(request)
                return preparedSubmission()
            }, emitTelemetry: { _ in })
        await #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try await router(bridge: nil, plumbing: plumbing)
                .streamChatCompletion(request: imageRequest())
        }
        #expect(capture.requests.isEmpty)
    }

    @Test func videoIsDecodedAndHandedToTheProcessorRatherThanRefused() async throws {
        // A decodable clip passes bounded ingest; only the stub's processor
        // identity stops it, after decode and before any tower work.
        let refusal = await #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try await EngineV2VisionPrefill.prepareGLM5NextMedia(
                container: stubContainer(),
                request: imageRequest([.text("What moves?"), .videoURL(tinyMP4DataURI)]),
                templateControls: .init())
        }
        guard case .unsupportedVLM? = refusal else {
            Issue.record("video stopped before the processor: \(String(describing: refusal))")
            return
        }
        // A malformed clip keeps the deterministic ingest fault (HTTP 400).
        await #expect(throws: MediaIngest.MediaError.self) {
            _ = try await EngineV2VisionPrefill.prepareGLM5NextMedia(
                container: stubContainer(),
                request: imageRequest([.text("x"), .videoURL("data:video/mp4;base64,AAAA")]),
                templateControls: .init())
        }
    }

    /// The readiness requests through the scheduler with GLM's actual request
    /// normalization, shared ingest and processor at the published budgets.
    /// The variable-frame-rate QuickTime clip was refused as `invalid_media`.
    @Test func openRouterReadinessVideosReachTheEngineInsteadOfInvalidMedia() async throws {
        let mov = try openRouterVideo(
            "input-video-base64.mov",
            sha256: "0a53a3aa1da409c54b57b6955139525f77c421893aaa172ebc1f86ba3a7323f4")
        let mp4 = try openRouterVideo(
            "input-video-url.mp4",
            sha256: "dc11648bd3546cd0a37ecc1077ccc426d42c409fe4822ece0354eb250804431e")
        // The URL test arrives as the coordinator's sniffed data:video/mp4 URI.
        for (label, data, grid) in [
            ("video/quicktime", mov, [11, 40, 108]),
            ("video/mp4", mp4, [5, 52, 92]),
        ] {
            let engine = GLMScriptedEngine()
            let bridge = EngineV2Bridge(
                engine: engine, modelId: "test/glm-stub", tokenizer: TokenizerHandle(GLMStubTokenizer()),
                eosTokenIds: [2], kvBytesPerToken: 0)
            let prepared = PreparedCapture()
            let plumbing = EngineV2VisionPlumbing(
                prepare: { _, request, controls in
                    let input = try await EngineV2VisionPrefill.glm5NextUserInput(
                        request: request, controls: controls)
                    let processor = try GLM5NextProcessor(
                        configuration: .init(), tokenizer: GLMMediaMarkerTokenizer())
                    do {
                        let output = try await processor.prepareDetailed(input: input)
                        prepared.record(
                            (output.input.video?.frames ?? []).map { [$0.t, $0.h, $0.w] }
                                + [output.placements.map(\.tokenRange.count)])
                    } catch let error as GLM5NextVisionError {
                        throw EngineV2VisionPrefill.glm5NextInputError(error)
                    }
                    return preparedSubmission()
                }, emitTelemetry: { _ in })
            let request = imageRequest([
                .text("What's in this video?"),
                .videoURL("data:\(label);base64," + data.base64EncodedString()),
            ])
            do {
                for try await _ in try await router(bridge: bridge, plumbing: plumbing)
                    .streamChatCompletion(request: request) {}
            } catch {
                let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
                Issue.record("\(label) refused as \(failure.code.rawValue): \(error)")
                continue
            }
            #expect(engine.submitted.count == 1, "\(label)")
            let spans = Array(repeating: grid[1] * grid[2] / 4, count: grid[0])
            #expect(prepared.values == [grid, spans], "\(label)")
        }
    }

    @Test func processorRefusalsAreDeterministicClientFaults() {
        for error in [
            GLM5NextVisionError.invalidInput("media count does not match rendered prompt"),
            .budgetExceeded("prepared pixels"), .unsupported("nonlocal or invalid image URL"),
        ] {
            guard case .unsupportedMedia(let detail)? =
                EngineV2VisionPrefill.glm5NextInputError(error) as? EngineV2VisionPrefillError
            else {
                Issue.record("processor refusal \(error) is not a client fault")
                continue
            }
            #expect(detail.hasPrefix("GLM media input: "))
        }
        // Weight faults are provider faults and keep the retriable refusal.
        #expect(
            EngineV2VisionPrefill.glm5NextInputError(.weightsNotLoaded) as? GLM5NextVisionError
                == .weightsNotLoaded)
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

    @Test func reservationChargesTowerWorkingSetAndFullImageTokenCaps() throws {
        let vision = try visionConfiguration()
        let processor = try GLM5NextProcessorConfiguration()
        let twoImages = imageRequest([.text("compare"), .imageURL(pngDataURI), .imageURL(pngDataURI)])
        let reservation = GLM5NextVisionBudget.reservation(
            request: twoImages, vision: vision, processor: processor,
            defaultMaxTokens: 64, contextLength: 1_000_000)
        let base = MediaIngest.projectedKVTokens(twoImages, defaultMaxTokens: 64, contextLength: 1_000_000)
        #expect(reservation.kvTokens == base + 2 * (8002 - MediaIngest.visionTokensPerImage))
        let working = GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision)
        #expect(reservation.bytes == UInt64(processor.maximumPreparedBytes) + working)
        // A full 8000-token frame: every buffer the per-frame Metal check
        // prices is covered, and the tiled scores never become a frame square.
        let patches = UInt64(GLM5NextVisionBudget.maximumFramePatches)
        #expect(working >= patches * 3 * 1024 * 4 + patches * 2 * 4096 * 4 + 16 * 128 * patches * 4)
        #expect(working < 16 * patches * patches * 4)
        #expect(
            GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision, patches: 1024)
                < working)
        // Clamped to the context window plus output.
        let clamped = GLM5NextVisionBudget.reservation(
            request: twoImages, vision: vision, processor: processor,
            defaultMaxTokens: 64, contextLength: 4096)
        #expect(clamped.kvTokens == 4096 + 8)
    }

    @Test func videoReservationChargesTheVideoTokenCeilingAndDecodedFrames() throws {
        let vision = try visionConfiguration()
        let processor = try GLM5NextProcessorConfiguration()
        // 28,532 prepared features, then 602 pairs of begin/end tokens and
        // "601.0 seconds", then the video's begin/end tokens.
        let ceiling = GLM5NextVisionBudget.videoTokenCeiling(processor: processor, maxDurationSeconds: 600)
        #expect(ceiling == 28_532 + 602 * (2 + 13) + 2)
        #expect(ceiling > MediaIngest.visionTokensPerVideo)
        #expect(GLM5NextVisionBudget.videoTokenCeiling(processor: processor, maxDurationSeconds: 1e300) > ceiling)
        let video = imageRequest([.text("What moves?"), .videoURL(tinyMP4DataURI)])
        let reservation = GLM5NextVisionBudget.reservation(
            request: video, vision: vision, processor: processor,
            defaultMaxTokens: 64, contextLength: 1_000_000)
        let base = MediaIngest.projectedKVTokens(video, defaultMaxTokens: 64, contextLength: 1_000_000)
        #expect(
            reservation.kvTokens == base + GLM5NextVisionBudget.videoTokenCeiling(processor: processor)
                - MediaIngest.visionTokensPerVideo)
        #expect(
            reservation.bytes == UInt64(processor.maximumPreparedBytes)
                + UInt64(processor.maximumDecodedBytes)
                + GLM5NextVisionBudget.towerWorkingSetBytes(configuration: vision))
        let clamped = GLM5NextVisionBudget.reservation(
            request: video, vision: vision, processor: processor,
            defaultMaxTokens: 64, contextLength: 4096)
        #expect(clamped.kvTokens == 4096 + 8)
    }
}
