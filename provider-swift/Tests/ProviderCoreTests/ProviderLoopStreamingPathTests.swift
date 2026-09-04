// Copyright © 2026 Eigen Labs.
//
// Live-isolated tests over the REAL coordinator request path: a sealed body
// through `ProviderLoop.handleInferenceRequest` (decrypt, admission, accept,
// warm slot, the detached generation task, `MultiModelBatchSchedulerEngine`
// → `MLXOpenAIService` → `EngineV2Bridge`), with only the CBv2 engine and
// the weights stubbed. The outbound side is a recorder on the same
// `SendHandle` the production loop uses, so terminals carry the live
// profile builder exactly as they would on the wire.
//
// Covers:
//   * a deadline refusal's 503 terminal carries the engine's projection on
//     its profile (T2-02);
//   * a coordinator cancel mid-stream settles as a partial completion with
//     the delivered tokens, cancel stamps in order, and no usage gap (T1-01);
//   * cancels for unknown ids and disconnect-driven cancel-all never consult
//     the runtime or rebuild capacity (T1-01);
//   * the per-request capacity rebuilds never sit between the engine and the
//     first chunk or the terminal (T1-02).

import Foundation
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

// MARK: - Scripted engine

/// Manual-script CBv2 engine: ordinary submits hand out a continuation the
/// test drives; the deadline submit returns the armed verdict; `capacity()`
/// can block the calling (bridge-actor) thread to simulate a slow snapshot.
private final class HarnessEngine: CBv2Engine, @unchecked Sendable {
    enum Verdict { case admit, refuseBounded, refuseUnbounded }

    private let lock = NSLock()
    private var _continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var _cancelled: [CBv2RequestID] = []
    private var _capacityCalls = 0
    private var _ordinarySubmits = 0
    private var _deadlineSubmits = 0
    private var _verdict: Verdict = .admit
    private var _capacityGate: CapacityGate?
    /// Invoked synchronously inside `cancel` (ordering assertions).
    var onCancel: (@Sendable (CBv2RequestID) -> Void)?

    var continuations: [AsyncStream<CBv2Event>.Continuation] { lock.withLock { _continuations } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var capacityCalls: Int { lock.withLock { _capacityCalls } }
    var ordinarySubmits: Int { lock.withLock { _ordinarySubmits } }
    var deadlineSubmits: Int { lock.withLock { _deadlineSubmits } }

    func arm(_ verdict: Verdict) { lock.withLock { _verdict = verdict } }
    /// Every `capacity()` read parks the caller on `gate` until the test
    /// releases it — the ordering-proof shape: "this frame landed while the
    /// neighbour's capacity read was still held" needs no clock.
    func holdCapacity(on gate: CapacityGate) { lock.withLock { _capacityGate = gate } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            _ordinarySubmits += 1
            _continuations.append(continuation)
        }
        return stream
    }

    func submit(
        _ request: CBv2Request,
        firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let verdict = lock.withLock {
            _deadlineSubmits += 1
            return _verdict
        }
        let bounded = CBv2FirstTokenProjectedWork.bounded(
            work: CBv2FirstTokenScheduledWork(
                prefillTokens: request.promptTokens.count,
                decodeTokens: 0,
                scheduledSteps: 1,
                mixedSteps: 0),
            serviceDuration: .milliseconds(7))
        switch verdict {
        case .admit:
            return .admitted(
                stream: try submit(request),
                projectedWork: bounded,
                admittedAt: .now,
                retirement: .acknowledged)
        case .refuseBounded:
            return .deadlineUnreachable(projectedWork: bounded)
        case .refuseUnbounded:
            return .deadlineUnreachable(projectedWork: .unbounded)
        }
    }

    /// Deliver an event on the most recent stream.
    func emit(_ event: CBv2Event) {
        lock.withLock { _continuations.last }?.yield(event)
    }

    func finishStream() {
        lock.withLock { _continuations.last }?.finish()
    }

    /// Records the cancel and — like the real engine at its next step
    /// boundary — terminates the row with `.finished(.cancelled)`.
    func cancel(_ id: CBv2RequestID) {
        let continuation = lock.withLock {
            _cancelled.append(id)
            return _continuations.last
        }
        onCancel?(id)
        continuation?.yield(.finished(
            reason: .cancelled,
            usage: CBv2Usage(promptTokens: 0, completionTokens: 0)))
        continuation?.finish()
    }

    func capacity() -> CBv2CapacitySnapshot {
        let gate = lock.withLock {
            _capacityCalls += 1
            return _capacityGate
        }
        gate?.park()
        return CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 1 << 30, activeTokens: 0)
    }

    func shutdown() async {}
}

/// A hold the test releases explicitly. `park()` blocks the calling thread —
/// the bridge actor's executor, exactly what a busy co-resident slot does to
/// a capacity rebuild — until `release()`. A 20 s safety timeout turns a
/// wrong ordering into a failed wait instead of a hung suite.
private final class CapacityGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _held = true
    private var _parked = 0

    /// Reads currently parked on the gate.
    var parked: Int { lock.withLock { _parked } }

    func park() {
        let held = lock.withLock { () -> Bool in
            guard _held else { return false }
            _parked += 1
            return true
        }
        guard held else { return }
        _ = semaphore.wait(timeout: .now() + 20)
        lock.withLock { _parked -= 1 }
    }

    /// Lower the hold: every parked read resumes, later reads pass through.
    func release() {
        let waiters = lock.withLock { () -> Int in
            guard _held else { return 0 }
            _held = false
            return _parked
        }
        for _ in 0..<waiters { semaphore.signal() }
    }
}

// MARK: - Stub weights

/// Counts chat-template renders across every `HarnessTokenizer` copy a
/// harness hands out (container, bridge and slot), so a test can assert how
/// many times the request path rendered the prompt — once at admission, and
/// never again during a cancel settlement that bills the engine's count.
private final class ChatTemplateRenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func bump() { lock.withLock { _count += 1 } }
}

private struct HarnessTokenizer: MLXLMCommon.Tokenizer {
    var renders = ChatTemplateRenderCounter()

    /// One token per whitespace-separated word: the cancelled-mid-stream
    /// settle re-tokenizes the delivered text as its completion floor, so the
    /// engine's one-token-per-word deltas below bill as one token each.
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.split(whereSeparator: { $0 == " " }).count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? { id == 2 ? "</s>" : nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    /// Five prompt tokens per render, counted: the admission render is the
    /// count the bridge seeds into `active[id]` (and publishes to the usage
    /// signal); any later render is the `promptTokenFloor` fallback.
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        renders.bump()
        return [1, 2, 3, 4, 5]
    }
}

private final class HarnessLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct HarnessProcessorError: Error {}

private struct HarnessProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput { throw HarnessProcessorError() }
}

private func makeHarnessContainer(
    renders: ChatTemplateRenderCounter = ChatTemplateRenderCounter()
) -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: HarnessLanguageModel(),
            processor: HarnessProcessor(),
            tokenizer: HarnessTokenizer(renders: renders)))
}

// MARK: - Outbound recorder

private final class OutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    private var chunkSeenAt: [ContinuousClock.Instant] = []
    private var terminalSeenAt: ContinuousClock.Instant?

    func append(_ message: OutboundMessage) {
        let now = ContinuousClock.now
        lock.withLock {
            messages.append(message)
            switch message {
            case .inferenceChunk: chunkSeenAt.append(now)
            case .inferenceComplete, .inferenceError: terminalSeenAt = now
            default: break
            }
        }
    }

    var kinds: [String] {
        lock.withLock {
            messages.map {
                switch $0 {
                case .inferenceAccepted: return "accepted"
                case .inferenceChunk: return "chunk"
                case .inferenceComplete: return "complete"
                case .inferenceError: return "error"
                default: return "other"
                }
            }
        }
    }

    var chunkCount: Int { lock.withLock { chunkSeenAt.count } }
    func chunkAt(index: Int) -> ContinuousClock.Instant? {
        lock.withLock { index < chunkSeenAt.count ? chunkSeenAt[index] : nil }
    }
    var terminalAt: ContinuousClock.Instant? { lock.withLock { terminalSeenAt } }

    var errors: [(failure: InferenceFailure, profile: RequestProfileBuilder?)] {
        lock.withLock {
            messages.compactMap {
                if case .inferenceError(_, let failure, let profile) = $0 {
                    return (failure, profile)
                }
                return nil
            }
        }
    }

    var completions: [(usage: UsageInfo, hash: String?, profile: RequestProfileBuilder?)] {
        lock.withLock {
            messages.compactMap {
                if case .inferenceComplete(_, let usage, _, _, let hash, let profile) = $0 {
                    return (usage, hash, profile)
                }
                return nil
            }
        }
    }

    var chunkPayloads: [EncryptedPayload] {
        lock.withLock {
            messages.compactMap {
                if case .inferenceChunk(_, _, let payload) = $0 { return payload }
                return nil
            }
        }
    }
}

// MARK: - Harness

private struct Harness {
    let loop: ProviderLoop
    let runtime: EngineV2Runtime
    let engine: HarnessEngine
    let bridge: EngineV2Bridge
    /// Chat-template renders across the slot, bridge and container
    /// tokenizers (one shared counter).
    let renders: ChatTemplateRenderCounter
    let modelId = "stub-model"

    static func make(
        deadlineMode: PrefillDeadlineMode = .off,
        seedIsolatedPrefillTps: Double? = nil
    ) async throws -> Harness {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
                chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "streaming-path-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        let loop = try ProviderLoop(
            config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let runtime = EngineV2Runtime()
        await loop.setEngineV2RuntimeForTesting(runtime)
        let engine = HarnessEngine()
        let renders = ChatTemplateRenderCounter()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "stub-model",
            tokenizer: TokenizerHandle(HarnessTokenizer(renders: renders)),
            eosTokenIds: [],
            prefillDeadlineMode: deadlineMode)
        #if DEBUG
        if let seedIsolatedPrefillTps {
            await bridge._testSeedIsolatedPrefillEwma(seedIsolatedPrefillTps)
        }
        #endif
        await runtime.register(modelId: "stub-model", bridge: bridge)
        await loop.installModelSlotForTesting(
            modelId: "stub-model",
            container: makeHarnessContainer(renders: renders),
            tokenizer: TokenizerHandle(HarnessTokenizer(renders: renders)),
            engineV2: bridge)
        return Harness(
            loop: loop, runtime: runtime, engine: engine, bridge: bridge, renders: renders)
    }

    /// Seal a chat body exactly as the coordinator does and hand it to the
    /// real handler on the loop actor. Returns once the handler has spawned
    /// (or refused) the generation task. `reasoning_parser: none` because a
    /// slot with no model type infers the qwen3 think parser, whose streaming
    /// state machine holds tagless output until end-of-stream — these tests
    /// are about the request path, not the parser.
    @discardableResult
    func submit(
        requestId: String,
        recorder: OutboundRecorder,
        sender: NodeKeyPair,
        budgetMilliseconds: Int64? = 9_000,
        maxTokens: Int = 16
    ) async throws -> Task<Void, Never> {
        let body = Data(
            #"{"model":"\#(modelId)","messages":[{"role":"user","content":"hi"}],"max_tokens":\#(maxTokens),"reasoning_parser":"none"}"#
                .utf8)
        let ciphertext = try sender.encrypt(
            recipientPublicKey: await loop.publicKeyBytesForTesting(),
            plaintext: body)
        let deadline = budgetMilliseconds.map {
            FirstContentDeadline(relativeBudgetMilliseconds: $0)
        }
        let loop = self.loop
        let senderPublicKey = sender.publicKeyBytes
        return Task {
            await loop.handleInferenceRequest(
                requestId: requestId,
                ciphertext: ciphertext,
                senderPublicKey: senderPublicKey,
                cacheReceiptNonce: nil,
                authenticatedCacheScope: nil,
                firstContentDeadline: deadline,
                send: SendHandle(recorder.append))
        }
    }

    /// Bounded wait until `condition` holds.
    func wait(
        _ description: String,
        timeout: Duration = .seconds(20),
        recorder: OutboundRecorder? = nil,
        until condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        let posture = "engine submits=\(engine.ordinarySubmits)/\(engine.deadlineSubmits) "
            + "continuations=\(engine.continuations.count) cancelled=\(engine.cancelled.count) "
            + "capacity=\(engine.capacityCalls) recorder=\(recorder?.kinds ?? [])"
        Issue.record("timed out waiting for \(description): \(posture)")
    }
}

@Suite("ProviderLoop coordinator request path (sealed body → chunks → terminal)", .serialized)
struct ProviderLoopStreamingPathTests {

    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    // MARK: T2-02 — the refusal terminal carries the projection

    #if DEBUG
    @Test("a projected deadline refusal's 503 terminal carries projected_* and the remaining budget, never engine_admitted")
    func refusalTerminalCarriesProjection() async throws {
        let h = try await Harness.make(deadlineMode: .enforce, seedIsolatedPrefillTps: 1_000)
        h.engine.arm(.refuseBounded)
        let recorder = OutboundRecorder()
        let sender = NodeKeyPair.generate()
        let handler = try await h.submit(
            requestId: "req-refused", recorder: recorder, sender: sender)
        _ = await handler.value
        try await h.wait("refusal terminal") { recorder.kinds.contains("error") }

        #expect(recorder.kinds == ["accepted", "error"])
        #expect(h.engine.deadlineSubmits == 1)
        #expect(h.engine.ordinarySubmits == 0)
        let (failure, profile) = try #require(recorder.errors.first)
        #expect(failure.statusCode == 503)
        #expect(failure.errorReason == .deadlineUnreachable)
        let wire = try #require(profile?.wireObject())
        #expect(wire.deadlineMode == .projected)
        #expect(wire.engineSubmitUs != nil)
        #expect(wire.engineAdmittedUs == nil)
        #expect(wire.projectedPrefillTokens == 5)
        #expect(wire.projectedDecodeTokens == 0)
        #expect(wire.projectedServiceUs == 7_000)
        let remaining = try #require(wire.budgetRemainingAtAdmitUs)
        #expect(remaining >= 0 && remaining <= 9_000_000)
        // The profile round-trips through the closed wire object (the Go
        // mirror decodes the same closed field set — ProtocolTests).
        let encoded = try JSONEncoder().encode(wire)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["projected_service_us"] as? Int == 7_000)
        #expect(object["engine_admitted_us"] == nil)
    }
    #endif

    // MARK: T1-01 — cancel path

    @Test("a coordinator cancel mid-stream settles as a partial completion: delivered tokens billed, cancel stamps ordered, no usage gap")
    func midStreamCancelSettlesPartialCompletion() async throws {
        let h = try await Harness.make()
        let recorder = OutboundRecorder()
        let sender = NodeKeyPair.generate()
        let statsBefore = (
            partial: await h.loop.stats.cancellationsPartialComplete,
            gaps: await h.loop.stats.usageGaps,
            received: await h.loop.stats.cancellationsReceived)
        let handler = try await h.submit(
            requestId: "req-mid-stream", recorder: recorder, sender: sender)
        _ = await handler.value
        try await h.wait("engine submission") { h.engine.ordinarySubmits == 1 }

        // Three content deltas reach the wire (the role preamble frame is
        // chunk #1, so content delta k is chunk k + 1).
        for (index, text) in ["Hello", " there", " world"].enumerated() {
            h.engine.emit(.delta(text: text, tokens: [10 + index], logprobs: nil))
            let expected = index + 2
            try await h.wait("chunk \(expected)", recorder: recorder) {
                recorder.chunkPayloads.count >= expected
            }
        }

        // Admission rendered the prompt exactly once — the count the bridge
        // seeded into `active[id]` and published to the usage signal.
        let rendersAtCancel = h.renders.count
        #expect(rendersAtCancel == 1)

        // The coordinator's cancel lands: the loop cancels the task first,
        // Task propagation reaches the bridge and the engine drops the row.
        await h.loop.handleCancellation(requestId: "req-mid-stream")
        try await h.wait("terminal after cancel", recorder: recorder) { recorder.terminalAt != nil }
        try await h.wait("engine cancel", recorder: recorder) { !h.engine.cancelled.isEmpty }

        // Partial settle: inference_complete with the delivered tokens, not
        // a bare 499 — the client is billed for what it received.
        #expect(recorder.kinds.last == "complete", "kinds: \(recorder.kinds)")
        #expect(recorder.errors.isEmpty)
        let completion = try #require(recorder.completions.first)
        #expect(completion.usage.completionTokens == 3)
        // T5-02: the prompt side is the engine's admission count read from
        // the usage signal, so settlement never re-renders the chat template
        // (the `promptTokenFloor` autoclosure stays unevaluated). Without the
        // handler's signal read the render count reads 2 — the floor
        // re-rendered — even though the number billed is the same 5.
        #expect(completion.usage.promptTokens == 5)
        #expect(h.renders.count == rendersAtCancel, "settlement re-rendered the prompt")
        let content = try recorder.chunkPayloads.map { payload -> String in
            let data = try sender.decryptPayload(payload)
            return String(decoding: data, as: UTF8.self)
        }.joined()
        #expect(content.contains("Hello"))
        #expect(content.contains(" world"))
        // Stats: one partial-complete cancel, no usage-gap false alarm.
        #expect(await h.loop.stats.cancellationsPartialComplete == statsBefore.partial + 1)
        #expect(await h.loop.stats.usageGaps == statsBefore.gaps)
        #expect(await h.loop.stats.cancellationsReceived == statsBefore.received + 1)
        // Profile: cancel receipt precedes the abort, so abort latency is measurable.
        let profile = try #require(completion.profile)
        let summary = profile.cancelSummary()
        let abortNs = try #require(summary.abortNs)
        #expect(abortNs > 0)
        #expect(profile.wireObject().cancelStage != nil)
    }

    #if DEBUG
    @Test("a cancel whose usage signal carries no engine prompt count falls back to the re-template floor")
    func midStreamCancelWithoutEngineCountReRendersPrompt() async throws {
        // Counterpart of the render assertion above: with the pump's publish
        // suppressed (the bridge seam stands in for a handler reading a
        // signal the pump never wrote) the settlement MUST evaluate
        // `promptTokenFloor` — one more chat-template render — and bill the
        // rendered count. Pins that the render counter really observes the
        // floor path the positive test claims is skipped.
        let h = try await Harness.make()
        await h.bridge._testSuppressPromptCountPublish()
        let recorder = OutboundRecorder()
        let sender = NodeKeyPair.generate()
        let handler = try await h.submit(
            requestId: "req-no-engine-count", recorder: recorder, sender: sender)
        _ = await handler.value
        try await h.wait("engine submission") { h.engine.ordinarySubmits == 1 }
        h.engine.emit(.delta(text: "Hello", tokens: [10], logprobs: nil))
        try await h.wait("first content chunk", recorder: recorder) {
            recorder.chunkPayloads.count >= 2
        }
        let rendersAtCancel = h.renders.count
        #expect(rendersAtCancel == 1)

        await h.loop.handleCancellation(requestId: "req-no-engine-count")
        try await h.wait("terminal after cancel", recorder: recorder) { recorder.terminalAt != nil }
        try await h.wait("engine cancel", recorder: recorder) { !h.engine.cancelled.isEmpty }

        #expect(recorder.kinds.last == "complete", "kinds: \(recorder.kinds)")
        let completion = try #require(recorder.completions.first)
        #expect(completion.usage.completionTokens == 1)
        #expect(completion.usage.promptTokens == 5)
        #expect(h.renders.count == rendersAtCancel + 1, "floor was not evaluated")
    }
    #endif

    @Test("a cancel for an id the loop never saw costs nothing: no runtime consult, no capacity rebuild")
    func unknownIdCancelIsFree() async throws {
        let h = try await Harness.make()
        #expect(await h.loop.hasEngineV2SlotsForTesting())
        let before = await h.runtime.consultCount
        await h.loop.handleCancellation(requestId: "req-never-seen")
        #expect(await h.runtime.consultCount == before)
        #expect(h.engine.cancelled.isEmpty)
        #expect(h.engine.capacityCalls == 0)
    }

    @Test("cancelling an in-flight request cancels its task BEFORE any runtime consult")
    func taskCancelPrecedesRuntimeConsult() async throws {
        let h = try await Harness.make()
        let order = OrderLog()
        h.engine.onCancel = { _ in order.append("runtime_cancel") }
        // A row the runtime fan-out can find (the coordinator id IS the
        // bridge id here, so the id-map path records `runtime_cancel`).
        let stream = await h.bridge.submit(
            request: ChatCompletionRequest(
                model: h.modelId, messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-order")
        let entered = OrderLog()
        let task = Task<Void, Never> {
            await withTaskCancellationHandler {
                entered.append("entered")
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            } onCancel: {
                order.append("task_cancel")
            }
        }
        try await h.wait("task entered") { !entered.events.isEmpty }
        await h.loop.registerInflightTaskForTesting(requestId: "req-order", task: task)

        await h.loop.handleCancellation(requestId: "req-order")
        _ = await task.value
        #expect(order.events == ["task_cancel", "runtime_cancel"])
        #expect(await h.runtime.consultCount == 1)
        withExtendedLifetime(stream) {}
    }

    @Test("cancelAllInflight cancels every task synchronously and rebuilds nothing")
    func cancelAllInflightIsAwaitFree() async throws {
        let h = try await Harness.make()
        let cancelled = OrderLog()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<8 {
            let task = Task<Void, Never> {
                await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                } onCancel: {
                    cancelled.append("task-\(index)")
                }
            }
            tasks.append(task)
            await h.loop.registerInflightTaskForTesting(requestId: "req-\(index)", task: task)
        }
        let before = await h.runtime.consultCount
        await h.loop.cancelAllInflight()
        for task in tasks { _ = await task.value }
        #expect(Set(cancelled.events).count == 8)
        #expect(await h.runtime.consultCount == before)
        #expect(h.engine.capacityCalls == 0)
        #expect(await h.loop.hasInflightWork == false)
    }

    // MARK: T1-02 — capacity rebuilds off the request path


    @Test("a co-resident slot whose capacity read is HELD delays neither the first chunk nor the terminal; the rebuilds still happen off-path")
    func capacityRebuildsNeverGateChunksOrTerminal() async throws {
        // Review fix (S1 P2): this used to assert `< 600 ms` wall-clock
        // bounds around a 400 ms `Thread.sleep` per capacity read, which a
        // loaded runner can violate with no regression in the code under
        // test (the bound was already widened once). It is now an ORDERING
        // proof: the neighbour's capacity read is parked on a gate the test
        // releases only after the frame in question has been recorded. If
        // any request-path hop awaited the rebuild (the pre-T1-02 shape:
        // the detached task awaited `updateAggregateCapacity()` before its
        // first frame and again before its terminal), the frame could not
        // arrive while the gate is held and the bounded wait fails.
        let h = try await Harness.make()
        let busyEngine = HarnessEngine()
        let gate = CapacityGate()
        defer { gate.release() }
        busyEngine.holdCapacity(on: gate)
        let busyBridge = EngineV2Bridge(
            engine: busyEngine,
            modelId: "busy-neighbour",
            tokenizer: TokenizerHandle(HarnessTokenizer()),
            eosTokenIds: [])
        await h.runtime.register(modelId: "busy-neighbour", bridge: busyBridge)
        let recorder = OutboundRecorder()
        let sender = NodeKeyPair.generate()
        let handler = try await h.submit(
            requestId: "req-latency", recorder: recorder, sender: sender)
        _ = await handler.value
        try await h.wait("engine submission") { h.engine.ordinarySubmits == 1 }

        // First token → the post-submit rebuild is detached; the first
        // CONTENT chunk (#2, after the role preamble) must land while the
        // neighbour's read is held.
        h.engine.emit(.delta(text: "Hello", tokens: [10], logprobs: nil))
        try await h.wait("first content chunk", recorder: recorder) { recorder.chunkCount >= 2 }
        // Make the hold load-bearing for the rest of the request: the
        // rebuild has reached the neighbour and is parked inside its FIRST
        // read (the second hop cannot start until the first returns).
        // (`capacity()` counts the call BEFORE it parks, so wait on the park
        // itself, not the count.)
        try await h.wait("post-submit rebuild parked on the neighbour") {
            gate.parked >= 1
        }
        #expect(busyEngine.capacityCalls == 1)
        #expect(gate.parked == 1)

        h.engine.emit(.delta(text: " world", tokens: [11], logprobs: nil))
        try await h.wait("second content chunk", recorder: recorder) { recorder.chunkCount >= 3 }
        h.engine.emit(.finished(
            reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)))
        h.engine.finishStream()
        try await h.wait("terminal", recorder: recorder) { recorder.terminalAt != nil }

        // ORDERING PROOF: the terminal landed while the rebuild was still
        // parked in its first neighbour read — neither the post-submit
        // rebuild nor a pre-terminal one gated it.
        #expect(busyEngine.capacityCalls == 1)
        #expect(gate.parked == 1)
        #expect(recorder.kinds.last == "complete")
        let completion = try #require(recorder.completions.first)
        #expect(completion.usage.completionTokens == 2)
        #expect(completion.usage.promptTokens == 5)
        #expect(completion.hash != nil)

        // Lower the hold: the post-submit rebuild and the finish rebuild
        // both complete off the request path — exactly two runtime consults
        // per request, each visiting the busy neighbour in two actor hops
        // that take THREE engine snapshot reads (`capacityInputs` reads the
        // grant and the slot claim; `backendSlotCapacity` reads once more).
        // The old `== 4` was a timing artifact of the 400 ms sleeps: reads
        // 5 and 6 had not landed when `>= 4` was observed.
        gate.release()
        try await h.wait("post-request rebuilds", timeout: .seconds(30), recorder: recorder) {
            busyEngine.capacityCalls >= 6
        }
        #expect(await h.runtime.consultCount == 2)
        #expect(busyEngine.capacityCalls == 6)
    }

    @Test("the per-slot MTP/KV-backend posture is sampled by the capacity tick, not by per-request rebuilds")
    func slotPosturesSampledOnTickOnly() async throws {
        let h = try await Harness.make()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dstate-tick-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await h.loop.setDaemonStateFileForTesting(stateURL)

        // The per-request rebuild leaves the posture untouched (no
        // `mtpStatusSnapshot` hop per slot on the request path).
        await h.loop.updateAggregateCapacity()
        #expect(await h.loop.lastLiveSlotPostures.isEmpty)
        // The tick samples it — one entry per loaded slot.
        await h.loop.capacityRefreshTick()
        let postures = await h.loop.lastLiveSlotPostures
        #expect(postures.map(\.model) == [h.modelId])
    }
}

/// Thread-safe append-only event log for ordering assertions.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func append(_ event: String) { lock.withLock { _events.append(event) } }
}
