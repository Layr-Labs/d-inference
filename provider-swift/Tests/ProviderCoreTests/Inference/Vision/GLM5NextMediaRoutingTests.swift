// Copyright © 2026 Eigen Labs.
//
// GLM-5.3-Flash media routing and reservation: a scripted in-process engine,
// a real `ModelContainer` over stub model/processor/tokenizer and an injected
// preparer. No model weights. The native builder itself is exercised by
// `GLM5NextManagedLoadTests` on synthetic GLM weights.

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

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpenAIChatCompletionRequest] = []
    var requests: [OpenAIChatCompletionRequest] { lock.withLock { values } }
    func record(_ request: OpenAIChatCompletionRequest) { lock.withLock { values.append(request) } }
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
