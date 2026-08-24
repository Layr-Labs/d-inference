// Copyright © 2026 Eigen Labs.
//
// Media-through-engine_v2 unit tests (v0.7.5 vision + video/fail-
// loud) — live-isolated style: a scripted in-process `CBv2Engine`, a real
// `ModelContainer` over stub model/processor/tokenizer, and an injected
// `EngineV2VisionPlumbing` preparer. No model weights, no network.
//
//   * Span carving: per-image and per-video-frame spans out of synthetic
//     tokenized prompts (1 image, 2 images, adjacent images,
//     image-at-start, video-only, mixed interleave, cross-kind adjacency)
//     + every mismatch rejection, including the video frame-count/
//     span-count assertion in both directions.
//   * Routing: image AND video requests on a v2-bridged VLM slot reach
//     the engine as a `CBv2Request` with the prepared prompt tokens, the
//     carved spans, and an embeddings closure returning the precomputed
//     arrays; text requests on the same slot stay `multimodal == nil`;
//     construction failure REFUSES loudly (`engine_v2_vision_refusal`
//     ERROR + `.requestRejected` → 503, never a legacy fallback);
//     `MediaError` out of construction keeps its deterministic 4xx;
//     non-bridged slots fail LOUD (no legacy path remains).
//   * Error mapping: submit-time `CBv2MultimodalError` → the canonical
//     `multimodal_rejected:` message → `.multimodalRejected` → HTTP 400.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

// A real, round-trip-verified 1x1 PNG (red pixel) — same fixture as
// MediaIngestTests; passes `validateMedia`'s real decode.
private let tinyPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

// A real, round-trip-verified 64x64 H.264 mp4 (3 solid-gray frames) — same
// fixture as MediaIngestTests; passes `validateMedia`'s real
// AVFoundation metadata probe, so video-bearing requests reach the v2
// routing branch in these tests.
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

// MARK: - Scripted engine / stubs

private final class VisionScriptedEngine: CBv2Engine, @unchecked Sendable {
    enum Script {
        case throwOnSubmit(any Error)
        case stream([CBv2Event])
        case manual
    }

    private let lock = NSLock()
    private let script: Script
    private var _submitted: [CBv2Request] = []
    private var _manualContinuation: AsyncStream<CBv2Event>.Continuation?

    init(script: Script) { self.script = script }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }
    var manualContinuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { _manualContinuation }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { _submitted.append(request) }
        switch script {
        case .throwOnSubmit(let error):
            throw error
        case .stream(let events):
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            for event in events { continuation.yield(event) }
            continuation.finish()
            return stream
        case .manual:
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            lock.withLock { _manualContinuation = continuation }
            return stream
        }
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct VisionStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        [1, 2, 3, 4, 5]
    }
}

/// Never forward-passed; exists so a real `ModelContainer` can be built.
private final class VisionStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

/// The legacy VLM path calls `ctx.processor.prepare` — this stub throws a
/// recognizable error, which doubles as the "the legacy path was taken"
/// signal in the fallback tests.
private struct VisionStubProcessorError: Error {}
private struct VisionStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw VisionStubProcessorError()
    }
}

private func makeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/vlm-stub"),
            model: VisionStubLanguageModel(),
            processor: VisionStubProcessor(),
            tokenizer: VisionStubTokenizer()
        ))
}

private final class VisionTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func callback() -> @Sendable (TelemetryEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            self.lock.withLock { self._events.append(event) }
        }
    }
}

private final class PrepareCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

private final class VisionRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [OpenAIChatMessage]?
    var messages: [OpenAIChatMessage]? { lock.withLock { _messages } }

    func record(_ request: OpenAIChatCompletionRequest) {
        lock.withLock { _messages = request.messages }
    }
}

// MARK: - Harness

/// One synthetic prepared submission: prompt `[7, 7, P, P, P, 8]` with a
/// single 3-token image span at offset 2 and one matching embedding.
private func makePreparedSubmission(
    mediaKind: EngineV2MediaKind = .image
) -> (
    submission: EngineV2VisionPrefill.PreparedSubmission, embedding: MLXArray
) {
    let embedding = MLXArray(Array(0 ..< 12).map(Float.init)).reshaped([3, 4])
    let submission = EngineV2VisionPrefill.PreparedSubmission(
        promptTokens: [7, 7, 990, 990, 990, 8],
        spans: [CBv2ImageSpan(tokenOffset: 2, length: 3)],
        embeddings: [embedding],
        attention: .bidirectionalSpans,
        positionState: nil,
        mediaKind: mediaKind
    )
    return (submission, embedding)
}

private func makeBridge(
    engine: VisionScriptedEngine, fixedRequestBytes: Int = 0,
    kvBudget: GlobalKVCacheBudget? = nil, telemetry: VisionTelemetrySink? = nil
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: "test/vlm-stub",
        tokenizer: TokenizerHandle(VisionStubTokenizer()),
        eosTokenIds: [2],
        kvBytesPerToken: 0,
        fixedRequestBytes: fixedRequestBytes,
        kvBudget: kvBudget,
        emitTelemetry: telemetry?.callback()
    )
}

/// Build the routing engine over one VLM slot entry. `visionGate` is the
/// per-slot media memory gate; nil (the default for most routing tests)
/// degrades to "always proceed" — reservation tests pass a gate over a
/// real `GlobalKVCacheBudget`.
private func makeRoutingEngine(
    container: ModelContainer?,
    bridge: EngineV2Bridge?,
    plumbing: EngineV2VisionPlumbing?,
    modelType: String = "gemma4",
    visionGate: VisionMemoryGate? = nil,
    reasoningEffort: String? = nil
) -> MultiModelBatchSchedulerEngine {
    MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in
            [
                "test/vlm-stub": .init(
                    tokenizer: TokenizerHandle(VisionStubTokenizer()),
                    modelType: modelType,
                    container: container,
                    isVLM: true,
                    engineV2Bridge: bridge,
                    visionGate: visionGate)
            ]
        },
        defaultMaxTokens: 64,
        reasoningEffort: reasoningEffort,
        engineV2Vision: plumbing
    )
}

private func imageRequest(parts: [OpenAIContentPart]? = nil) -> OpenAIChatCompletionRequest {
    OpenAIChatCompletionRequest(
        model: "test/vlm-stub",
        messages: [
            OpenAIChatMessage(
                role: .user,
                content: .parts(
                    parts ?? [.text("what is this?"), .imageURL(tinyPNGDataURI)]))
        ],
        temperature: 0,
        maxTokens: 8
    )
}

private func collectContent(
    _ stream: AsyncThrowingStream<MLXServerGenerationEvent, Error>
) async throws -> String {
    var content = ""
    for try await event in stream {
        if case .content(let text) = event { content += text }
    }
    return content
}

/// One media memory gate over a real 64 GiB `GlobalKVCacheBudget`, for the
/// tests that assert reserve/release accounting on the media path (the
/// budget-less routing tests pass no gate at all).
private func makeBudgetedVisionGate() -> (gate: VisionMemoryGate, budget: GlobalKVCacheBudget) {
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(
            total: 64 * 1024 * 1024 * 1024, active: 0, cache: 0, systemAvailable: .max)
    }
    let gate = VisionMemoryGate(
        kvBudget: budget, fp16KVBytesPerToken: 1024, contextLength: 4096)
    return (gate, budget)
}

// MARK: - Span carving

@Suite("EngineV2VisionPrefill span carving")
struct EngineV2VisionSpanCarvingTests {
    let p = 990  // image placeholder id
    let v = 991  // video placeholder id

    /// Image-only convenience over the generalized two-kind carve.
    private func carveImages(tokens: [Int], spanLengths: [Int]) throws -> [CBv2ImageSpan] {
        try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: spanLengths,
            videoPlaceholderId: nil, videoSpanLengths: []
        ).map(\.span)
    }

    @Test("single image mid-prompt")
    func singleImage() throws {
        let tokens = [1, 5, 6, p, p, p, p, 9]
        let spans = try carveImages(tokens: tokens, spanLengths: [4])
        #expect(spans == [CBv2ImageSpan(tokenOffset: 3, length: 4)])
    }

    @Test("two images separated by text/delimiters")
    func twoImages() throws {
        let tokens = [1, p, p, 42, 43, p, p, 9]
        let spans = try carveImages(tokens: tokens, spanLengths: [2, 2])
        #expect(spans == [
            CBv2ImageSpan(tokenOffset: 1, length: 2),
            CBv2ImageSpan(tokenOffset: 5, length: 2),
        ])
    }

    @Test("adjacent images carve one run into back-to-back spans")
    func adjacentImages() throws {
        // One contiguous 5-token run = a 2-token image + a 3-token image;
        // the engine coalesces the two spans back into one bidirectional
        // block (the wrapper's contiguous-run semantics).
        let tokens = [1, p, p, p, p, p, 9]
        let spans = try carveImages(tokens: tokens, spanLengths: [2, 3])
        #expect(spans == [
            CBv2ImageSpan(tokenOffset: 1, length: 2),
            CBv2ImageSpan(tokenOffset: 3, length: 3),
        ])
    }

    @Test("image at prompt start")
    func imageAtStart() throws {
        let tokens = [p, p, p, 4, 5]
        let spans = try carveImages(tokens: tokens, spanLengths: [3])
        #expect(spans == [CBv2ImageSpan(tokenOffset: 0, length: 3)])
    }

    @Test("missing placeholder run throws")
    func missingRun() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [1, 2, 3], spanLengths: [2])
        }
    }

    @Test("run shorter than the image's soft-token count throws")
    func runTooShort() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [1, p, p, 4], spanLengths: [3])
        }
    }

    @Test("leftover placeholders after pairing throw")
    func trailingPlaceholders() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [1, p, p, 4, p, 9], spanLengths: [2])
        }
    }

    @Test("non-positive feature length throws")
    func invalidLength() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [p], spanLengths: [0])
        }
    }

    // MARK: video + mixed (v0.7.5)

    @Test("video-only: one span per frame block, timestamps/text between")
    func videoOnlyPerFrame() throws {
        // Two frame blocks (3 soft tokens each), separated by the timestamp
        // text tokens the processor emits between per-frame blocks — the
        // engine never coalesces across frames because of them.
        let tokens = [1, 60, v, v, v, 61, 60, v, v, v, 61, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: nil, imageSpanLengths: [],
            videoPlaceholderId: v, videoSpanLengths: [3, 3])
        #expect(carved == [
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 2, length: 3)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 7, length: 3)),
        ])
    }

    @Test("mixed image+video preserves prompt-order interleave")
    func mixedInterleave() throws {
        // image, frame, frame, image — spans must come out ascending with
        // per-kind features consumed in prompt order.
        let tokens = [1, p, p, 5, v, v, v, 6, v, v, v, 7, p, p, p, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: [2, 3],
            videoPlaceholderId: v, videoSpanLengths: [3, 3])
        #expect(carved == [
            EngineV2VisionPrefill.CarvedSpan(
                kind: .image, span: CBv2ImageSpan(tokenOffset: 1, length: 2)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 4, length: 3)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 8, length: 3)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .image, span: CBv2ImageSpan(tokenOffset: 12, length: 3)),
        ])
    }

    @Test("cross-kind adjacency: image run directly followed by a frame run")
    func crossKindAdjacency() throws {
        let tokens = [p, p, v, v, v, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: [2],
            videoPlaceholderId: v, videoSpanLengths: [3])
        #expect(carved == [
            EngineV2VisionPrefill.CarvedSpan(
                kind: .image, span: CBv2ImageSpan(tokenOffset: 0, length: 2)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 2, length: 3)),
        ])
    }

    @Test("fewer video runs than frames throws (frame-count assertion)")
    func fewerRunsThanFrames() {
        // Tower returned 2 frames, prompt has only 1 frame block.
        do {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [1, v, v, v, 9], imagePlaceholderId: nil, imageSpanLengths: [],
                videoPlaceholderId: v, videoSpanLengths: [3, 3])
            Issue.record("expected placeholderRunMissing throw")
        } catch let error as EngineV2VisionPrefillError {
            guard case .placeholderRunMissing(let kind, let index) = error else {
                Issue.record("expected .placeholderRunMissing, got \(error)")
                return
            }
            #expect(kind == .video)
            #expect(index == 1)
        } catch {
            Issue.record("expected EngineV2VisionPrefillError, got \(error)")
        }
    }

    @Test("more video runs than frames throws (frame-count assertion)")
    func moreRunsThanFrames() {
        // Tower returned 1 frame, prompt has 2 frame blocks.
        do {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [1, v, v, v, 5, v, v, v, 9], imagePlaceholderId: nil,
                imageSpanLengths: [],
                videoPlaceholderId: v, videoSpanLengths: [3])
            Issue.record("expected unexpectedTrailingPlaceholders throw")
        } catch let error as EngineV2VisionPrefillError {
            guard case .unexpectedTrailingPlaceholders(let kind, let count) = error else {
                Issue.record("expected .unexpectedTrailingPlaceholders, got \(error)")
                return
            }
            #expect(kind == .video)
            #expect(count == 3)
        } catch {
            Issue.record("expected EngineV2VisionPrefillError, got \(error)")
        }
    }

    @Test("video frame run shorter than its soft-token count throws")
    func videoRunTooShort() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [1, v, v, 5], imagePlaceholderId: nil, imageSpanLengths: [],
                videoPlaceholderId: v, videoSpanLengths: [3])
        }
    }

    @Test("image and video sharing one placeholder id throws")
    func conflictingIds() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [p, p], imagePlaceholderId: p, imageSpanLengths: [2],
                videoPlaceholderId: p, videoSpanLengths: [2])
        }
    }

    @Test("a disabled kind's id is an ordinary token (mirrors the processor)")
    func disabledKindIgnored() throws {
        // No video features ⇒ the video id is not watched: a stray 991 in
        // the prompt stays an ordinary token, exactly as the wrapper would
        // embed it (the processor only expands placeholders it produced
        // pixels for).
        let tokens = [1, p, p, 4, v, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: [2],
            videoPlaceholderId: nil, videoSpanLengths: [])
        #expect(carved.map(\.span) == [CBv2ImageSpan(tokenOffset: 1, length: 2)])
    }
}

// MARK: - Media-kind classification

@Suite("MediaIngest.hasVideo + EngineV2VisionPrefill.mediaKind")
struct MediaKindClassificationTests {
    @Test("media processor receives the request's reasoning template switch")
    func reasoningTemplateContext() async throws {
        for enabled in [false, true] {
            var request = imageRequest()
            request.reasoning = OpenAIReasoningConfig(enabled: enabled)
            let input = try await MediaIngest.buildUserInput(from: request)
            #expect(input.additionalContext?["enable_thinking"] as? Bool == enabled)
        }
    }

    @Test("media processor preserves out-of-band reasoning effort")
    func reasoningEffortTemplateContext() async throws {
        let request = imageRequest()
        let input = try await MediaIngest.buildUserInput(
            from: request, reasoningEffort: "high")
        #expect(input.additionalContext?["reasoning_effort"] as? String == "high")
    }

    @Test("image-only request has no video and classifies as .image")
    func imageOnly() {
        #expect(!MediaIngest.hasVideo(imageRequest()))
        #expect(EngineV2VisionPrefill.mediaKind(of: imageRequest()) == .image)
    }

    @Test("video part is detected; video/mixed classify correctly")
    func videoDetected() {
        let video = imageRequest(parts: [.videoURL("data:video/mp4;base64,AAAA")])
        #expect(MediaIngest.hasVideo(video))
        #expect(EngineV2VisionPrefill.mediaKind(of: video) == .video)
        let mixed = imageRequest(parts: [
            .imageURL(tinyPNGDataURI), .videoURL("data:video/mp4;base64,AAAA"),
        ])
        #expect(MediaIngest.hasVideo(mixed))
        #expect(EngineV2VisionPrefill.mediaKind(of: mixed) == .mixed)
    }

    @Test("mediaKind ignores non-user-role media (mirrors buildUserInput)")
    func nonUserRolesIgnored() {
        // A video part on an assistant message is dropped by buildUserInput,
        // so the kind must reflect the user-message media only — keeping
        // refusal tags consistent with the success path's lmInput-derived
        // kind.
        let request = OpenAIChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [
                OpenAIChatMessage(
                    role: .assistant,
                    content: .parts([.videoURL("data:video/mp4;base64,AAAA")])),
                OpenAIChatMessage(
                    role: .user,
                    content: .parts([.text("what is this?"), .imageURL(tinyPNGDataURI)])),
            ],
            temperature: 0,
            maxTokens: 8
        )
        #expect(EngineV2VisionPrefill.mediaKind(of: request) == .image)
    }
}

// MARK: - Bridge multimodal passthrough

@Suite("EngineV2Bridge multimodal submit")
struct EngineV2BridgeMultimodalTests {

    init() {
        // MLXArray comparisons below force evaluation — the metallib must be
        // colocated with the test runner (CI copies it into the bundle; the
        // fixture self-heals locally from .build/debug).
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("multimodal input rides CBv2Request verbatim; INFO telemetry tagged multimodal")
    func multimodalPassthrough() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "Red", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let telemetry = VisionTelemetrySink()
        let bridge = makeBridge(engine: engine, telemetry: telemetry)
        let (prepared, embedding) = makePreparedSubmission()

        let request = ChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0, max_tokens: 8)
        let stream = await bridge.submitTokenized(
            promptTokens: prepared.promptTokens,
            request: request,
            requestId: "req-vision-1",
            multimodal: prepared.multimodalInput(),
            mediaKind: .video
        )
        var text = ""
        for await event in stream {
            if case .chunk(let chunk) = event { text += chunk }
        }
        #expect(text == "Red")

        let submitted = try #require(engine.submitted.first)
        #expect(submitted.promptTokens == prepared.promptTokens)
        let multimodal = try #require(submitted.multimodal)
        #expect(multimodal.spans == prepared.spans)
        let arrays = try multimodal.embeddings()
        #expect(arrays.count == 1)
        #expect(arrays[0].shape == embedding.shape)
        #expect(arrays[0].asArray(Float.self) == embedding.asArray(Float.self))

        // Engagement telemetry: INFO, engine_v2_vision, multimodal=true,
        // media_kind riding the caller-supplied tag.
        let visionEvents = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision"
        }
        #expect(visionEvents.count == 1)
        #expect(visionEvents.first?.fields?["multimodal"]?.description == "true")
        #expect(visionEvents.first?.fields?["media_kind"]?.description == "video")
        #expect(visionEvents.first?.fields?["backend"]?.description == "engine_v2")
        #expect(visionEvents.first?.requestId == "req-vision-1")
    }

    @Test("Qwen position state rides the multimodal input into CBv2Request")
    func qwenPositionStatePassthrough() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .finished(
                    reason: .stop,
                    usage: CBv2Usage(promptTokens: 3, completionTokens: 0))
            ]))
        let bridge = makeBridge(engine: engine)
        let positions = CBv2PositionState(
            promptPositionIds: MLXArray([
                Int32(0), 1, 2,
                0, 4, 5,
                0, 7, 8,
            ]).reshaped([3, 1, 3]),
            decodeDeltas: [-2])
        let input = CBv2MultimodalInput(
            spans: [CBv2ImageSpan(tokenOffset: 1, length: 1)],
            attention: .causal,
            positionState: positions
        ) { [MLXArray.ones([1, 1, 4])] }
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 990, 2],
            request: ChatCompletionRequest(
                model: "test/vlm-stub",
                messages: [ChatMessage(role: "user", content: "x")],
                max_tokens: 1),
            requestId: "qwen-position-passthrough",
            multimodal: input,
            mediaKind: .image)
        for await _ in stream {}

        let submitted = try #require(engine.submitted.first)
        let submittedPositions = try #require(submitted.positionState)
        #expect(submitted.multimodal?.attention == .causal)
        #expect(submittedPositions.decodeDeltas == [-2])
        #expect(submittedPositions.promptLength == 3)
    }

    @Test("text submit keeps multimodal nil and emits no vision telemetry")
    func textSubmitUnchanged() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
            ]))
        let telemetry = VisionTelemetrySink()
        let bridge = makeBridge(engine: engine, telemetry: telemetry)
        let request = ChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0, max_tokens: 8)
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: request, requestId: "req-text-1")
        for await _ in stream {}
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.multimodal == nil)
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision"
            })
    }
}

@Suite("Qwen35 CBv2 fixed request accounting")
struct Qwen35CBv2FixedRequestAccountingTests {
    @Test("fixed recurrent bytes reserve exactly and release at terminal")
    func exactReservationAndRelease() async {
        let engine = VisionScriptedEngine(script: .manual)
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9, activationReserveBytes: 0,
            memorySnapshot: {
                .init(
                    total: 64 * 1024 * 1024 * 1024,
                    active: 0, cache: 0, systemAvailable: .max)
            })
        let bridge = makeBridge(
            engine: engine,
            fixedRequestBytes: 193_167_360,
            kvBudget: budget)
        let stream = await bridge.submitTokenized(
            promptTokens: [1],
            request: ChatCompletionRequest(
                model: "test/vlm-stub",
                messages: [ChatMessage(role: "user", content: "x")],
                max_tokens: 1),
            requestId: "qwen-fixed-accounting")
        #expect(await budget.outstandingReservedBytes() == 193_167_360)
        let consumer = Task {
            for await _ in stream {}
        }
        engine.manualContinuation?.yield(
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 1, completionTokens: 0)))
        engine.manualContinuation?.finish()
        _ = await consumer.value
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(engine.submitted.count == 1)
    }
}

// MARK: - Routing through streamChatCompletion

@Suite("MultiModelBatchSchedulerEngine vision-v2 routing")
struct EngineV2VisionRoutingTests {

    init() {
        // Some assertions evaluate MLXArrays (embedding comparisons) — see
        // EngineV2BridgeMultimodalTests.init.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("image request on a bridged slot submits through the engine with spans + embeddings")
    func imageRequestRoutesThroughV2() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "It is red.", tokens: [10, 11], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 2)),
            ]))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        let content = try await collectContent(
            try await router.streamChatCompletion(request: imageRequest()))
        #expect(content == "It is red.")
        #expect(counter.count == 1)

        let submitted = try #require(engine.submitted.first)
        #expect(submitted.promptTokens == prepared.promptTokens)
        #expect(try #require(submitted.multimodal).spans == prepared.spans)
    }

    @Test("Qwen media path normalizes late system turns before vision preparation")
    func qwenMediaNormalizesLateSystemTurn() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "ok", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        let capture = VisionRequestCapture()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, request, _ in
                capture.record(request)
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge,
            plumbing: plumbing,
            modelType: "qwen3_5_moe")
        var request = imageRequest()
        request.messages.append(.init(
            role: .system, content: .text("late vision policy")))

        let content = try await collectContent(
            try await router.streamChatCompletion(request: request))
        #expect(content == "ok")
        let messages = try #require(capture.messages)
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages[0].content == .text("late vision policy"))
        #expect(messages[1].content.hasMedia)
    }

    @Test("v2 success path releases the vision memory reservation exactly once")
    func visionReservationReleasedOnV2Path() async throws {
        // Real GlobalKVCacheBudget behind the slot's VisionMemoryGate so the
        // media reservation is NOT a no-op (the other routing tests run
        // gate-less): after the v2 stream completes, no reservation may
        // remain outstanding — a leak here would shrink admission headroom
        // one image request at a time. (The bridge itself runs without a
        // budget, so any outstanding bytes belong to the vision reservation.)
        let (gate, budget) = makeBudgetedVisionGate()
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "ok", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing, visionGate: gate)

        let content = try await collectContent(
            try await router.streamChatCompletion(request: imageRequest()))
        #expect(content == "ok")
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("near-headroom vision request is NOT double-charged across the submit handoff")
    func visionHandoffDoesNotDoubleCharge() async throws {
        // The vision reservation (media decode + full KV span) and the
        // bridge's shared-budget reservation charge the SAME
        // `GlobalKVCacheBudget`. The handoff must release the vision
        // reservation BEFORE `submitTokenized` re-reserves the span — a
        // budget that fits EITHER reservation alone but not both at once
        // must still serve the request. (Pre-fix, the temporary
        // double-charge rejected it with `token_budget_exhausted`.)
        let request = imageRequest()  // maxTokens = 8
        let (prepared, _) = makePreparedSubmission()

        // Reproduce the router's own gate arithmetic exactly (same
        // MediaIngest projections, same defaultMaxTokens: 64 as
        // makeRoutingEngine) so the sizing below is deterministic. Rates
        // are scaled so each reservation lands around 8 GiB — far above
        // the cap's fixed 2 GiB OS floor, so `hardCapBytes` stays
        // fraction/floor-exact at this scale.
        let gib: UInt64 = 1_073_741_824
        let gateContext = 4096
        let kvTokens = MediaIngest.projectedKVTokens(
            request, defaultMaxTokens: 64, contextLength: gateContext)
        let gateRate = Int(8 * gib / UInt64(max(1, kvTokens)))
        let gateReservation = MediaIngest.projectedDecodeBytes(request)
            + UInt64(gateRate * kvTokens)
        let worstCaseTokens = prepared.promptTokens.count + (request.maxTokens ?? 64)
        let bridgeRate = max(1, Int(gateReservation) / worstCaseTokens)
        let bridgeReservation = UInt64(bridgeRate * worstCaseTokens)

        // Cap between max(single) and the sum: each ~8 GiB reservation
        // fits alone under the ~12 GiB cap; holding both at once (~16 GiB)
        // would exceed it. `hardCapBytes = min(0.9·total, total − 2 GiB)`,
        // so total = cap + 2 GiB yields exactly `cap` (0.9·total ≥ cap
        // at this scale).
        let cap = gateReservation + bridgeReservation / 2
        let total = cap + UnifiedMemoryCap.minimumReserveBytes
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(
                total: total, active: 0, cache: 0, systemAvailable: .max)
        }
        let gate = VisionMemoryGate(
            kvBudget: budget, fp16KVBytesPerToken: gateRate,
            contextLength: gateContext)

        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "fits", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "test/vlm-stub",
            tokenizer: TokenizerHandle(VisionStubTokenizer()),
            eosTokenIds: [2],
            kvBytesPerToken: bridgeRate,
            kvBudget: budget
        )
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing, visionGate: gate)

        let content = try await collectContent(
            try await router.streamChatCompletion(request: request))
        #expect(content == "fits")

        // Both reservations must fully drain by stream end (the bridge
        // releases its span on the terminal event; the vision reservation
        // was released at the handoff).
        var outstanding = await budget.outstandingReservedBytes()
        let deadline = ContinuousClock.now + .seconds(5)
        while outstanding != 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            outstanding = await budget.outstandingReservedBytes()
        }
        #expect(outstanding == 0)
    }

    @Test("construction failure REFUSES loudly: ERROR telemetry + 503, no legacy fallback")
    func constructionFailureRefusesLoudly() async throws {
        struct PrepFailure: Error {}
        // Real budget behind the slot's gate so the vision reservation is
        // NOT a no-op: the refusal path must release it (a leak would shrink
        // admission headroom one refused request at a time).
        let (gate, budget) = makeBudgetedVisionGate()
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw PrepFailure() },
            emitTelemetry: telemetry.callback()
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing, visionGate: gate)

        // The stub container's processor would throw VisionStubProcessorError
        // if any fallback ever consulted it — seeing `.requestRejected`
        // instead is the proof the request was REFUSED, never re-served.
        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected requestRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .requestRejected(let message) = error else {
                Issue.record("expected .requestRejected, got \(error)")
                return
            }
            #expect(message.contains("media=image"))
            // Retriable 503 → the coordinator's pre-content failover
            // reroutes to another provider.
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 503)
        } catch {
            Issue.record("expected MultiModelBatchSchedulerEngineError, got \(error)")
        }
        #expect(engine.submitted.isEmpty, "the engine must never see a failed construction")
        #expect(await budget.outstandingReservedBytes() == 0)

        let refusals = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision_refusal"
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.severity == .error)
        #expect(refusals.first?.fields?["multimodal"]?.description == "true")
        #expect(refusals.first?.fields?["media_kind"]?.description == "image")
        #expect(
            refusals.first?.fields?["error_class"]?.description.contains("PrepFailure") == true)
        // No fallback WARN exists anymore.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_fallback"
            })
    }

    @Test("MediaError out of construction keeps its deterministic 4xx (not a refusal)")
    func mediaErrorFromConstructionKeeps4xx() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                throw MediaIngest.MediaError.mediaTooLarge("test-cap")
            },
            emitTelemetry: telemetry.callback()
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected MediaError throw")
        } catch let error as MediaIngest.MediaError {
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        } catch {
            Issue.record("expected MediaError, got \(error)")
        }
        #expect(engine.submitted.isEmpty)
        // A client input fault is not a v2 refusal — no ERROR event.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
    }

    @Test("noProcessedMedia (media on non-user roles only) maps to 400, not a refusal")
    func noProcessedMediaMapsTo400() async throws {
        // Without this mapping the shape would 503 → the coordinator's
        // failover would burn retries on a request that fails identically
        // on every provider (buildUserInput drops non-user media
        // everywhere).
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw EngineV2VisionPrefillError.noProcessedMedia },
            emitTelemetry: telemetry.callback()
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected multimodalRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .multimodalRejected(let message) = error else {
                Issue.record("expected .multimodalRejected, got \(error)")
                return
            }
            #expect(message.hasPrefix("multimodal_rejected:"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        } catch {
            Issue.record("expected MultiModelBatchSchedulerEngineError, got \(error)")
        }
        #expect(engine.submitted.isEmpty)
        // A deterministic client shape is not a v2 refusal — no ERROR event.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
    }

    @Test("unsupported Qwen video maps to deterministic 400 without refusal telemetry")
    func unsupportedVideoMapsTo400() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                throw EngineV2VisionPrefillError.unsupportedMedia(
                    "Qwen35MoE video media is not production-proven")
            },
            emitTelemetry: telemetry.callback())
        let router = makeRoutingEngine(
            container: makeStubContainer(), bridge: bridge, plumbing: plumbing)

        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected multimodalRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .multimodalRejected(let message) = error else {
                Issue.record("expected .multimodalRejected, got \(error)")
                return
            }
            #expect(message.contains("video media is not production-proven"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
        #expect(engine.submitted.isEmpty)
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
    }

    @Test("vision plumbing receives out-of-band reasoning effort")
    func visionPlumbingReceivesReasoningEffort() async throws {
        let engine = VisionScriptedEngine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        final class EffortBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func set(_ newValue: String?) { lock.withLock { value = newValue } }
            func get() -> String? { lock.withLock { value } }
        }
        let effort = EffortBox()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, reasoningEffort in
                effort.set(reasoningEffort)
                return prepared
            }, emitTelemetry: { _ in })
        let router = makeRoutingEngine(
            container: makeStubContainer(), bridge: bridge, plumbing: plumbing,
            reasoningEffort: "medium")

        _ = try await collectContent(
            try await router.streamChatCompletion(request: imageRequest()))
        #expect(effort.get() == "medium")
    }

    @Test("refusal on a video request tags media_kind video")
    func refusalTagsVideoKind() async throws {
        struct PrepFailure: Error {}
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw PrepFailure() },
            emitTelemetry: telemetry.callback()
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        // Real tinyMP4 so validateMedia passes and the preparer is reached.
        let request = imageRequest(parts: [
            .text("what happens in this clip?"), .videoURL(tinyMP4DataURI),
        ])
        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: request))
            Issue.record("expected requestRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .requestRejected(let message) = error else {
                Issue.record("expected .requestRejected, got \(error)")
                return
            }
            #expect(message.contains("media=video"))
        } catch {
            Issue.record("expected MultiModelBatchSchedulerEngineError, got \(error)")
        }
        let refusals = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision_refusal"
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.fields?["media_kind"]?.description == "video")
    }

    @Test("non-bridged slot fails LOUD on media (no legacy wrapper path left)")
    func nonBridgedSlotFailsLoud() async throws {
        // ONE ENGINE (v0.7.5): the legacy VLM wrapper stream is deleted.
        // Every production slot carries a v2 bridge, so a media request on a
        // bridge-less slot is a wiring bug — a hard internal error (500-
        // shaped generationFailed), never a silent legacy serve. The
        // preparer must not be consulted on the way to the backstop.
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: nil, plumbing: plumbing)
        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected generationFailed throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .generationFailed(let message) = error else {
                Issue.record("expected .generationFailed, got \(error)")
                return
            }
            #expect(message.contains("no serving engine for media"))
        }
        #expect(counter.count == 0)
    }

    @Test("video request on a bridged slot routes through v2 with media_kind tagged")
    func videoRoutesThroughV2() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "A gray clip.", tokens: [10, 11], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 2)),
            ]))
        let telemetry = VisionTelemetrySink()
        let bridge = makeBridge(engine: engine, telemetry: telemetry)
        let (prepared, _) = makePreparedSubmission(mediaKind: .video)
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        // The real tinyMP4 passes `validateMedia`'s AVFoundation probe, so
        // the request reaches the v2 branch (a pre-release draft gated video to legacy
        // here; v0.7.5 routes it through the engine).
        let request = imageRequest(parts: [
            .text("what happens in this clip?"), .videoURL(tinyMP4DataURI),
        ])
        let content = try await collectContent(
            try await router.streamChatCompletion(request: request))
        #expect(content == "A gray clip.")
        #expect(counter.count == 1)

        let submitted = try #require(engine.submitted.first)
        #expect(submitted.promptTokens == prepared.promptTokens)
        #expect(try #require(submitted.multimodal).spans == prepared.spans)

        // The routing site threads the prepared submission's media kind
        // into the bridge's engagement INFO.
        let visionEvents = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision"
        }
        #expect(visionEvents.count == 1)
        #expect(visionEvents.first?.fields?["media_kind"]?.description == "video")
    }

    @Test("garbage inline video still dies in validateMedia (4xx) before the preparer")
    func garbageVideoRejectedBeforePreparer() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)
        // The garbage inline video dies in `validateMedia` (a 400-class
        // MediaError) BEFORE the v2 attempt — the preparer must not fire
        // and the engine must stay untouched.
        let request = imageRequest(parts: [
            .imageURL(tinyPNGDataURI), .videoURL("data:video/mp4;base64,AAAA"),
        ])
        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: request))
            Issue.record("expected MediaError throw")
        } catch let error as MediaIngest.MediaError {
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        } catch {
            Issue.record("expected MediaError, got \(error)")
        }
        #expect(counter.count == 0)
        #expect(engine.submitted.isEmpty)
    }

    @Test("text request on a bridged VLM slot stays on the text path (multimodal nil)")
    func textRequestUnaffected() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "hello", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
            ]))
        let bridge = makeBridge(engine: engine)
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)
        let request = OpenAIChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))],
            temperature: 0,
            maxTokens: 8
        )
        let content = try await collectContent(
            try await router.streamChatCompletion(request: request))
        #expect(content == "hello")
        #expect(counter.count == 0)
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.multimodal == nil)
    }

    @Test("cancel during vision construction propagates as cancellation (499), not refusal or 500")
    func cancelDuringVisionConstructionPropagatesCancellation() async throws {
        // The consumer cancelled while the vision features were being built
        // (handleCancellation cancels the request task; the preparer's
        // container/tokenizer work observes it as CancellationError). The
        // routing seam must NOT burn a refusal ERROR or reject the request
        // — it releases and rethrows — and the handler-side mapping must
        // report the canonical cancellation (499), never a 500
        // .inferenceError (which would count as a provider fault and trip
        // the (provider, model) 5xx routing cooldown for a client's own
        // cancel).
        let (gate, budget) = makeBudgetedVisionGate()
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw CancellationError() },
            emitTelemetry: telemetry.callback()
        )
        let releaseCount = PrepareCallCounter()
        let container = makeStubContainer()
        let router = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "test/vlm-stub": .init(
                        tokenizer: TokenizerHandle(VisionStubTokenizer()),
                        modelType: "gemma4",
                        container: container,
                        isVLM: true,
                        engineV2Bridge: bridge,
                        visionGate: gate)
                ]
            },
            releaseModel: { @Sendable _ in releaseCount.increment() },
            defaultMaxTokens: 64,
            engineV2Vision: plumbing
        )

        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected CancellationError throw")
        } catch is CancellationError {
            // Handler-side contract: the pre-stream catch reports this as
            // the canonical cancellation, and the generic mapper backstops
            // every other call site with 499 — never 500.
            #expect(ProviderLoop.mapInferenceErrorToStatus(CancellationError()) == 499)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        // No refusal ERROR (this was not a v2 failure), engine untouched
        // (never submitted), model reservation released exactly once, and
        // the vision memory reservation fully released.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
        #expect(engine.submitted.isEmpty)
        #expect(releaseCount.count == 1)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("engine-side CBv2MultimodalError surfaces as .multimodalRejected → 400")
    func engineMultimodalRejectionMapsTo400() async throws {
        let engine = VisionScriptedEngine(
            script: .throwOnSubmit(CBv2MultimodalError.invalidSpans("test detail")))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        do {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
            Issue.record("expected multimodalRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .multimodalRejected(let message) = error else {
                Issue.record("expected .multimodalRejected, got \(error)")
                return
            }
            #expect(message.hasPrefix("multimodal_rejected:"))
            #expect(message.contains("test detail"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
    }
}

// MARK: - Error-message mapping units

@Suite("CBv2MultimodalError → multimodal_rejected mapping")
struct MultimodalErrorMappingTests {

    @Test("every CBv2MultimodalError case maps to the multimodal_rejected prefix")
    func admissionMessages() {
        let cases: [CBv2MultimodalError] = [
            .unsupportedModel("m"),
            .unsupportedBackend("b"),
            .invalidSpans("s"),
            .spanTooLong(blockTokens: 560, maxBatchedTokensPerStep: 512),
            .embeddingMismatch("e"),
        ]
        for error in cases {
            let message = EngineV2Translation.admissionErrorMessage(for: error)
            #expect(
                message.hasPrefix(EngineV2Translation.multimodalRejectedPrefix),
                Comment(rawValue: "case \(error) mapped to \(message)"))
            // And the round trip: message → typed error → 400.
            let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            guard case .multimodalRejected = typed else {
                Issue.record("expected .multimodalRejected for \(message), got \(typed)")
                continue
            }
            #expect(ProviderLoop.mapInferenceErrorToStatus(typed) == 400)
        }
    }

    @Test("spanTooLong carries both figures in the message")
    func spanTooLongMessage() {
        let message = EngineV2Translation.admissionErrorMessage(
            for: CBv2MultimodalError.spanTooLong(
                blockTokens: 560, maxBatchedTokensPerStep: 512))
        #expect(message.contains("560"))
        #expect(message.contains("512"))
    }

    @Test("capacity errors are unaffected by the new prefix check")
    func capacityErrorsUnchanged() {
        let message = EngineV2Translation.admissionErrorMessage(
            for: CBv2KVError.capacityExhausted(needed: 100, available: 10))
        let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(typed == .tokenBudgetExhausted(message))
    }
}
