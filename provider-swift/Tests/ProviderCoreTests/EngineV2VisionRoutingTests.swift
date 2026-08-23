// Copyright © 2026 Eigen Labs.
//
// Deterministic VLM routing and capacity tests over a scripted in-process
// `CBv2Engine`, stub model/processor/tokenizer, and injected vision plumbing.
// Embedded image/video fixtures exercise validation without model weights or
// network access.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

// A real, round-trip-verified 1x1 PNG (red pixel) — same fixture as
// MediaIngestTests; passes `validateMedia`'s real decode.
let visionTinyPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

// A real, round-trip-verified 64x64 H.264 mp4 (3 solid-gray frames) — same
// fixture as MediaIngestTests; passes `validateMedia`'s real
// AVFoundation metadata probe, so video-bearing requests reach the v2
// routing branch in these tests.
let visionTinyMP4DataURI =
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

// MLX resolves its metallib beside the xctest executable. Keep the deterministic
// vision tests self-contained instead of depending on the live-model fixture.
private final class VisionBundleSentinel {}

func visionEnsureMetallibColocated() -> URL? {
    MLXMetallibEnvironment.withExclusiveAccess {
        let fileManager = FileManager.default
        guard let executableDirectory = visionTestBundleExecutableDirectory(),
              let source = visionSourceMetallib()
        else {
            return nil
        }

        let destination = executableDirectory.appendingPathComponent("mlx.metallib")
        let temporary = executableDirectory
            .appendingPathComponent(".mlx.metallib.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            try fileManager.copyItem(at: source, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            MLXMetallibEnvironment.setPath(destination.path)
            return destination
        } catch {
            MLXMetallibEnvironment.setPath(source.path)
            return nil
        }
    }
}

private func visionTestBundleExecutableDirectory() -> URL? {
    let bundle = Bundle(for: VisionBundleSentinel.self)
    if let executable = bundle.executableURL {
        return executable.deletingLastPathComponent()
    }
    let directory = bundle.bundleURL
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
    return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
}

private func visionSourceMetallib() -> URL? {
    let fileManager = FileManager.default
    let bundle = Bundle(for: VisionBundleSentinel.self)
    let components = bundle.bundleURL.pathComponents
    let configuration: String
    if let buildIndex = components.lastIndex(of: ".build"),
       let activeConfiguration = components[components.index(after: buildIndex)...]
        .first(where: { $0 == "debug" || $0 == "release" }) {
        configuration = activeConfiguration
    } else {
        configuration = "debug"
    }

    var cursor = bundle.bundleURL
    for _ in 0 ..< 12 {
        if cursor.lastPathComponent == ".build" {
            let candidates = [
                cursor.appendingPathComponent("\(configuration)/mlx.metallib"),
                cursor.appendingPathComponent(
                    "arm64-apple-macosx/\(configuration)/mlx.metallib"),
            ]
            return candidates.first { fileManager.fileExists(atPath: $0.path) }
        }
        let parent = cursor.deletingLastPathComponent()
        if parent.path == cursor.path { break }
        cursor = parent
    }
    return nil
}

// MARK: - Scripted engine / stubs

final class VisionScriptedEngine: CBv2Engine, @unchecked Sendable {
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

struct VisionStubTokenizer: MLXLMCommon.Tokenizer {
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
struct VisionStubProcessorError: Error {}
private struct VisionStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw VisionStubProcessorError()
    }
}

func visionMakeStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/vlm-stub"),
            model: VisionStubLanguageModel(),
            processor: VisionStubProcessor(),
            tokenizer: VisionStubTokenizer()
        ))
}

final class VisionTelemetrySink: @unchecked Sendable {
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

final class VisionPrepareCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

final class VisionRequestCapture: @unchecked Sendable {
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
func visionMakePreparedSubmission(
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

func visionMakeBridge(
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
func visionMakeRoutingEngine(
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

func visionImageRequest(parts: [OpenAIContentPart]? = nil) -> OpenAIChatCompletionRequest {
    OpenAIChatCompletionRequest(
        model: "test/vlm-stub",
        messages: [
            OpenAIChatMessage(
                role: .user,
                content: .parts(
                    parts ?? [.text("what is this?"), .imageURL(visionTinyPNGDataURI)]))
        ],
        temperature: 0,
        maxTokens: 8
    )
}

func visionCollectContent(
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
func visionMakeBudgetedVisionGate() -> (gate: VisionMemoryGate, budget: GlobalKVCacheBudget) {
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(
            total: 64 * 1024 * 1024 * 1024, active: 0, cache: 0, systemAvailable: .max)
    }
    let gate = VisionMemoryGate(
        kvBudget: budget, fp16KVBytesPerToken: 1024, contextLength: 4096)
    return (gate, budget)
}

// MARK: - VLM capacity accounting

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
        let bridge = visionMakeBridge(
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
        _ = visionEnsureMetallibColocated()
    }

    @Test("image request on a bridged slot submits through the engine with spans + embeddings")
    func imageRequestRoutesThroughV2() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "It is red.", tokens: [10, 11], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 2)),
            ]))
        let bridge = visionMakeBridge(engine: engine)
        let (prepared, _) = visionMakePreparedSubmission()
        let counter = VisionPrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        let content = try await visionCollectContent(
            try await router.streamChatCompletion(request: visionImageRequest()))
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
        let bridge = visionMakeBridge(engine: engine)
        let (prepared, _) = visionMakePreparedSubmission()
        let capture = VisionRequestCapture()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, request, _ in
                capture.record(request)
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge,
            plumbing: plumbing,
            modelType: "qwen3_5_moe")
        var request = visionImageRequest()
        request.messages.append(.init(
            role: .system, content: .text("late vision policy")))

        let content = try await visionCollectContent(
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
        let (gate, budget) = visionMakeBudgetedVisionGate()
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "ok", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 1)),
            ]))
        let bridge = visionMakeBridge(engine: engine)
        let (prepared, _) = visionMakePreparedSubmission()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing, visionGate: gate)

        let content = try await visionCollectContent(
            try await router.streamChatCompletion(request: visionImageRequest()))
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
        let request = visionImageRequest()  // maxTokens = 8
        let (prepared, _) = visionMakePreparedSubmission()

        // Reproduce the router's own gate arithmetic exactly (same
        // MediaIngest projections, same defaultMaxTokens: 64 as
        // visionMakeRoutingEngine) so the sizing below is deterministic. Rates
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
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing, visionGate: gate)

        let content = try await visionCollectContent(
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

    @Test("vision plumbing receives out-of-band reasoning effort")
    func visionPlumbingReceivesReasoningEffort() async throws {
        let engine = VisionScriptedEngine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 0))
        ]))
        let bridge = visionMakeBridge(engine: engine)
        let (prepared, _) = visionMakePreparedSubmission()
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
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(), bridge: bridge, plumbing: plumbing,
            reasoningEffort: "medium")

        _ = try await visionCollectContent(
            try await router.streamChatCompletion(request: visionImageRequest()))
        #expect(effort.get() == "medium")
    }

    @Test("video request on a bridged slot routes through v2 with media_kind tagged")
    func videoRoutesThroughV2() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "A gray clip.", tokens: [10, 11], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 6, completionTokens: 2)),
            ]))
        let telemetry = VisionTelemetrySink()
        let bridge = visionMakeBridge(engine: engine, telemetry: telemetry)
        let (prepared, _) = visionMakePreparedSubmission(mediaKind: .video)
        let counter = VisionPrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                return prepared
            },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        // The real tinyMP4 passes `validateMedia`'s AVFoundation probe, so
        // the request reaches the v2 branch (a pre-release draft gated video to legacy
        // here; v0.7.5 routes it through the engine).
        let request = visionImageRequest(parts: [
            .text("what happens in this clip?"), .videoURL(visionTinyMP4DataURI),
        ])
        let content = try await visionCollectContent(
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

    @Test("text request on a bridged VLM slot stays on the text path (multimodal nil)")
    func textRequestUnaffected() async throws {
        let engine = VisionScriptedEngine(
            script: .stream([
                .delta(text: "hello", tokens: [10], logprobs: nil),
                .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
            ]))
        let bridge = visionMakeBridge(engine: engine)
        let counter = VisionPrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)
        let request = OpenAIChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))],
            temperature: 0,
            maxTokens: 8
        )
        let content = try await visionCollectContent(
            try await router.streamChatCompletion(request: request))
        #expect(content == "hello")
        #expect(counter.count == 0)
        let submitted = try #require(engine.submitted.first)
        #expect(submitted.multimodal == nil)
    }

}

