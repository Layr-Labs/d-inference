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
//     its profile (T2-02).

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
    private var _capacityBlock: TimeInterval = 0
    /// Invoked synchronously inside `cancel` (ordering assertions).
    var onCancel: (@Sendable (CBv2RequestID) -> Void)?

    var continuations: [AsyncStream<CBv2Event>.Continuation] { lock.withLock { _continuations } }
    var cancelled: [CBv2RequestID] { lock.withLock { _cancelled } }
    var capacityCalls: Int { lock.withLock { _capacityCalls } }
    var ordinarySubmits: Int { lock.withLock { _ordinarySubmits } }
    var deadlineSubmits: Int { lock.withLock { _deadlineSubmits } }

    func arm(_ verdict: Verdict) { lock.withLock { _verdict = verdict } }
    /// Every `capacity()` read blocks the caller for this long.
    func blockCapacity(seconds: TimeInterval) { lock.withLock { _capacityBlock = seconds } }

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
        let block = lock.withLock {
            _capacityCalls += 1
            return _capacityBlock
        }
        if block > 0 { Thread.sleep(forTimeInterval: block) }
        return CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 1 << 30, activeTokens: 0)
    }

    func shutdown() async {}
}

// MARK: - Stub weights

private struct HarnessTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? { id == 2 ? "</s>" : nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [1, 2, 3, 4, 5] }
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

private func makeHarnessContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/stub-model"),
            model: HarnessLanguageModel(),
            processor: HarnessProcessor(),
            tokenizer: HarnessTokenizer()))
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
    var firstChunkAt: ContinuousClock.Instant? { lock.withLock { chunkSeenAt.first } }
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
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "stub-model",
            tokenizer: TokenizerHandle(HarnessTokenizer()),
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
            container: makeHarnessContainer(),
            tokenizer: TokenizerHandle(HarnessTokenizer()),
            engineV2: bridge)
        return Harness(loop: loop, runtime: runtime, engine: engine, bridge: bridge)
    }

    /// Seal a chat body exactly as the coordinator does and hand it to the
    /// real handler on the loop actor. Returns once the handler has spawned
    /// (or refused) the generation task.
    @discardableResult
    func submit(
        requestId: String,
        recorder: OutboundRecorder,
        sender: NodeKeyPair,
        budgetMilliseconds: Int64? = 9_000,
        maxTokens: Int = 16
    ) async throws -> Task<Void, Never> {
        let body = Data(
            #"{"model":"\#(modelId)","messages":[{"role":"user","content":"hi"}],"max_tokens":\#(maxTokens)}"#
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
        until condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(description)")
    }
}

private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000.0
        + Double(duration.components.attoseconds) / 1e15
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
}
