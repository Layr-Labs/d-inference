// Copyright © 2026 Eigen Labs.
//
// v0.7.4 vision-through-engine_v2 unit tests — live-isolated style: a
// scripted in-process `CBv2Engine`, a real (unloaded) `BatchScheduler`, a
// real `ModelContainer` over stub model/processor/tokenizer, and an
// injected `EngineV2VisionPlumbing` preparer. No model weights, no network.
//
//   * Span carving: per-image spans out of synthetic tokenized prompts
//     (1 image, 2 images, adjacent images, image-at-start) + every
//     mismatch rejection.
//   * Routing: an image request on a v2-bridged VLM slot reaches the
//     engine as a `CBv2Request` with the prepared prompt tokens, the
//     carved spans, and an embeddings closure returning the precomputed
//     arrays; text requests on the same slot stay `multimodal == nil`;
//     construction failure falls back to the legacy VLM path with a WARN;
//     non-bridged slots and video-bearing requests never invoke the
//     preparer.
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
// VLMRequestInferenceTests; passes `validateMedia`'s real decode.
private let tinyPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

// MARK: - Scripted engine / stubs

private final class VisionScriptedEngine: CBv2Engine, @unchecked Sendable {
    enum Script {
        case throwOnSubmit(any Error)
        case stream([CBv2Event])
    }

    private let lock = NSLock()
    private let script: Script
    private var _submitted: [CBv2Request] = []

    init(script: Script) { self.script = script }

    var submitted: [CBv2Request] { lock.withLock { _submitted } }

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

// MARK: - Harness

/// One synthetic prepared submission: prompt `[7, 7, P, P, P, 8]` with a
/// single 3-token image span at offset 2 and one matching embedding.
private func makePreparedSubmission() -> (
    submission: EngineV2VisionPrefill.PreparedSubmission, embedding: MLXArray
) {
    let embedding = MLXArray(Array(0 ..< 12).map(Float.init)).reshaped([3, 4])
    let submission = EngineV2VisionPrefill.PreparedSubmission(
        promptTokens: [7, 7, 990, 990, 990, 8],
        spans: [CBv2ImageSpan(tokenOffset: 2, length: 3)],
        embeddings: [embedding]
    )
    return (submission, embedding)
}

private func makeBridge(
    engine: VisionScriptedEngine, telemetry: VisionTelemetrySink? = nil
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine,
        modelId: "test/vlm-stub",
        tokenizer: TokenizerHandle(VisionStubTokenizer()),
        eosTokenIds: [2],
        emitTelemetry: telemetry?.callback()
    )
}

/// Build the routing engine over one VLM slot entry.
private func makeRoutingEngine(
    scheduler: BatchScheduler,
    container: ModelContainer?,
    bridge: EngineV2Bridge?,
    plumbing: EngineV2VisionPlumbing?
) -> MultiModelBatchSchedulerEngine {
    MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in
            [
                "test/vlm-stub": .init(
                    scheduler: scheduler,
                    tokenizer: TokenizerHandle(VisionStubTokenizer()),
                    modelType: "gemma4",
                    container: container,
                    isVLM: true,
                    engineV2Bridge: bridge)
            ]
        },
        defaultMaxTokens: 64,
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

private func makeUnloadedScheduler() -> BatchScheduler {
    BatchScheduler(
        maxConcurrentRequests: 4,
        pendingTimeout: .seconds(30),
        defaultMaxTokens: 64
    )
}

// MARK: - Span carving

@Suite("EngineV2VisionPrefill span carving")
struct EngineV2VisionSpanCarvingTests {
    let p = 990  // placeholder id

    @Test("single image mid-prompt")
    func singleImage() throws {
        let tokens = [1, 5, 6, p, p, p, p, 9]
        let spans = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, placeholderId: p, spanLengths: [4])
        #expect(spans == [CBv2ImageSpan(tokenOffset: 3, length: 4)])
    }

    @Test("two images separated by text/delimiters")
    func twoImages() throws {
        let tokens = [1, p, p, 42, 43, p, p, 9]
        let spans = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, placeholderId: p, spanLengths: [2, 2])
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
        let spans = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, placeholderId: p, spanLengths: [2, 3])
        #expect(spans == [
            CBv2ImageSpan(tokenOffset: 1, length: 2),
            CBv2ImageSpan(tokenOffset: 3, length: 3),
        ])
    }

    @Test("image at prompt start")
    func imageAtStart() throws {
        let tokens = [p, p, p, 4, 5]
        let spans = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, placeholderId: p, spanLengths: [3])
        #expect(spans == [CBv2ImageSpan(tokenOffset: 0, length: 3)])
    }

    @Test("missing placeholder run throws")
    func missingRun() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try EngineV2VisionPrefill.carveSpans(
                tokens: [1, 2, 3], placeholderId: p, spanLengths: [2])
        }
    }

    @Test("run shorter than the image's soft-token count throws")
    func runTooShort() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try EngineV2VisionPrefill.carveSpans(
                tokens: [1, p, p, 4], placeholderId: p, spanLengths: [3])
        }
    }

    @Test("leftover placeholders after pairing throw")
    func trailingPlaceholders() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try EngineV2VisionPrefill.carveSpans(
                tokens: [1, p, p, 4, p, 9], placeholderId: p, spanLengths: [2])
        }
    }

    @Test("non-positive feature length throws")
    func invalidLength() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try EngineV2VisionPrefill.carveSpans(
                tokens: [p], placeholderId: p, spanLengths: [0])
        }
    }
}

// MARK: - hasVideo gate

@Suite("VLMRequestInference.hasVideo")
struct HasVideoGateTests {
    @Test("image-only request has no video")
    func imageOnly() {
        #expect(!VLMRequestInference.hasVideo(imageRequest()))
    }

    @Test("video part is detected, including mixed with images")
    func videoDetected() {
        let video = imageRequest(parts: [.videoURL("data:video/mp4;base64,AAAA")])
        #expect(VLMRequestInference.hasVideo(video))
        let mixed = imageRequest(parts: [
            .imageURL(tinyPNGDataURI), .videoURL("data:video/mp4;base64,AAAA"),
        ])
        #expect(VLMRequestInference.hasVideo(mixed))
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
            multimodal: prepared.multimodalInput()
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

        // Engagement telemetry: INFO, engine_v2_vision, multimodal=true.
        let visionEvents = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision"
        }
        #expect(visionEvents.count == 1)
        #expect(visionEvents.first?.fields?["multimodal"]?.description == "true")
        #expect(visionEvents.first?.fields?["backend"]?.description == "engine_v2")
        #expect(visionEvents.first?.requestId == "req-vision-1")
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
            prepare: { _, _ in
                counter.increment()
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            scheduler: makeUnloadedScheduler(), container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        let content = try await collectContent(
            try await router.streamChatCompletion(request: imageRequest()))
        #expect(content == "It is red.")
        #expect(counter.count == 1)

        let submitted = try #require(engine.submitted.first)
        #expect(submitted.promptTokens == prepared.promptTokens)
        #expect(try #require(submitted.multimodal).spans == prepared.spans)
    }

    @Test("v2 success path releases the vision memory reservation exactly once")
    func visionReservationReleasedOnV2Path() async throws {
        // Real GlobalKVCacheBudget on the scheduler so reserveVisionRequest/
        // releaseVisionRequest are NOT no-ops (the other routing tests run
        // budget-less): after the v2 stream completes, no reservation may
        // remain outstanding — a leak here would shrink admission headroom
        // one image request at a time. (The bridge itself runs without a
        // budget, so any outstanding bytes belong to the vision reservation.)
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(
                total: 64 * 1024 * 1024 * 1024, active: 0, cache: 0, systemAvailable: .max)
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(30),
            defaultMaxTokens: 64,
            kvBudget: budget
        )
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "ok", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            scheduler: scheduler, container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        let content = try await collectContent(
            try await router.streamChatCompletion(request: imageRequest()))
        #expect(content == "ok")
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("construction failure falls back to the legacy VLM path with a WARN")
    func constructionFailureFallsBackToLegacy() async throws {
        struct PrepFailure: Error {}
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _ in throw PrepFailure() },
            emitTelemetry: telemetry.callback()
        )
        let router = makeRoutingEngine(
            scheduler: makeUnloadedScheduler(), container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        // The stub container's processor throws on the legacy path — that
        // recognizable error IS the proof the request fell through to the
        // legacy VLM stream instead of being dropped or dying on the v2
        // attempt.
        await #expect(throws: VisionStubProcessorError.self) {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
        }
        #expect(engine.submitted.isEmpty, "the engine must never see a failed construction")

        let fallbacks = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision_fallback"
        }
        #expect(fallbacks.count == 1)
        #expect(fallbacks.first?.severity == .warn)
        #expect(fallbacks.first?.fields?["multimodal"]?.description == "true")
        #expect(
            fallbacks.first?.fields?["error_class"]?.description.contains("PrepFailure") == true)
    }

    @Test("non-bridged slot keeps the legacy path; the preparer is never invoked")
    func nonBridgedSlotStaysLegacy() async throws {
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            scheduler: makeUnloadedScheduler(), container: makeStubContainer(),
            bridge: nil, plumbing: plumbing)
        await #expect(throws: VisionStubProcessorError.self) {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: imageRequest()))
        }
        #expect(counter.count == 0)
    }

    @Test("video-bearing request never reaches the v2 preparer")
    func videoStaysOffV2() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = makeBridge(engine: engine)
        let counter = PrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            scheduler: makeUnloadedScheduler(), container: makeStubContainer(),
            bridge: bridge, plumbing: plumbing)
        // The garbage inline video dies in `validateMedia` (a 400-class
        // MediaError) — BEFORE the v2 attempt; and even a valid video would
        // be gated off v2 by `hasVideo`. Either way the preparer must not
        // fire and the engine must stay untouched.
        let request = imageRequest(parts: [
            .imageURL(tinyPNGDataURI), .videoURL("data:video/mp4;base64,AAAA"),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await collectContent(
                try await router.streamChatCompletion(request: request))
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
            prepare: { _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            scheduler: makeUnloadedScheduler(), container: makeStubContainer(),
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

    @Test("engine-side CBv2MultimodalError surfaces as .multimodalRejected → 400")
    func engineMultimodalRejectionMapsTo400() async throws {
        let engine = VisionScriptedEngine(
            script: .throwOnSubmit(CBv2MultimodalError.invalidSpans("test detail")))
        let bridge = makeBridge(engine: engine)
        let (prepared, _) = makePreparedSubmission()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = makeRoutingEngine(
            scheduler: makeUnloadedScheduler(), container: makeStubContainer(),
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
