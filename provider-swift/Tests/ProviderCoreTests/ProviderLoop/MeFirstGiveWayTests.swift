import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

#if DEBUG
/// Me first re-routes rather than preempts. While the owner's request waits for this Mac's engine, each Darkbloom request
/// that has sent no output ends with the typed drain refusal (`capacity`, 503, `draining`). The coordinator then serves it
/// on another Mac before anything reaches its client, with no health strike against this one. A Darkbloom request that
/// has streamed output keeps running and finishes. Shared mode changes nothing. The engine is a two-request queue with
/// no tensors; the network requests travel the encrypted coordinator path, the owner's the local engine's.
@Suite("Me first: Darkbloom work that hasn't answered gives way to the owner", .serialized, .timeLimit(.minutes(1)))
struct MeFirstGiveWayTests {
    static let model = "fixture-model"

    struct Harness {
        let loop: ProviderLoop
        let engine: GiveWayEngine
        let bridge: EngineV2Bridge
        let runtime: EngineV2Runtime
        let sender = NodeKeyPair.generate()
        let outbound: GiveWayOutbound

        /// A Darkbloom request, encrypted as the coordinator sends one; it is in the engine when this returns.
        func network(_ id: String) async throws {
            let submitted = engine.submittedCount
            let body = try JSONSerialization.data(withJSONObject: [
                "model": MeFirstGiveWayTests.model, "messages": [["role": "user", "content": "fixture"]],
                "max_tokens": 8, "stream": true, "reasoning_parser": "none",
            ])
            let encrypted = try sender.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: body)
            await loop.handleInferenceRequest(requestId: id, ciphertext: encrypted,
                senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil,
                authenticatedCacheScope: "give-way-tenant", send: SendHandle(outbound.record))
            try #require(await eventually { engine.submittedCount == submitted + 1 }, "\(id) reached the engine")
        }

        /// The owner's request through this Mac's local engine; it is in the engine when this returns.
        func owner() async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            let submitted = engine.submittedCount
            let loop = loop
            let tokenizer = TokenizerHandle(CancelledPrefixTokenizer(prompt: [1, 2, 3]))
            let local = MultiModelBatchSchedulerEngine(
                acquire: { try await loop.acquireModelForLocal($0) },
                tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: nil) },
                availableModels: { [MeFirstGiveWayTests.model] })
            let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(
                #"{"model":"\#(MeFirstGiveWayTests.model)","messages":[{"role":"user","content":"hi"}],"max_tokens":8}"#
                    .utf8))
            let events = try await local.streamChatCompletion(request: request)
            try #require(await eventually { engine.submittedCount == submitted + 1 }, "the owner's request reached the engine")
            return events
        }

        func remove() async {
            await bridge.shutdown()
            _ = await runtime.unregister(modelId: MeFirstGiveWayTests.model)
        }
    }

    static func harness(meFirst: Bool) async throws -> Harness {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: .init(provider: .init(name: "me-first-give-way"),
                backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil, kvBudgetForTesting: budget)
        await loop.skipCapacityRebuildForTesting()
        await loop.skipTerminalMemoryReadForTesting()
        if meFirst { await loop.enableMeFirst(idle: .seconds(60)) }
        let engine = GiveWayEngine(slots: 2)
        let tokenizer = CancelledPrefixTokenizer(prompt: [1, 2, 3])
        let bridge = EngineV2Bridge(engine: engine, modelId: model,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [],
            kvBytesPerToken: 4_000, kvBudget: budget)
        await bridge.setQueuePollIntervalForTesting(.milliseconds(10))
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: model, bridge: bridge)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(modelId: model,
            container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 4_000,
                maxContextLength: 8192, defaultMaxTokens: 4096))
        return Harness(loop: loop, engine: engine, bridge: bridge, runtime: runtime,
                       outbound: GiveWayOutbound())
    }

    /// Two network requests run (one streaming, one in its prompt) and a third waits behind them; then the owner's
    /// request waits too. The two that haven't answered are re-routed, the owner's request runs, and the streaming one
    /// finishes as if nothing happened.
    @Test func aLocalRequestBehindQueuedAndPrefillingNetworkWorkIsAdmittedOnceTheyAreReRouted() async throws {
        let h = try await Self.harness(meFirst: true)
        try await h.network("streaming")
        try await h.network("prefilling")
        try await h.network("queued")
        #expect(h.engine.waiting == [2])
        h.engine.token(0)
        try #require(await eventually { h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 1 })

        let owner = try await h.owner()
        #expect(await eventually { h.engine.running.contains(3) }, "the owner's request runs once the others give way")
        for id in ["prefilling", "queued"] {
            #expect(h.outbound.terminals(for: id) == 1, "\(id): one terminal")
            let refusal = h.outbound.failure(for: id)
            #expect(refusal?.code == .capacity && refusal?.statusCode == 503 && refusal?.errorReason == .draining,
                    "\(id) is re-routed with the typed drain refusal")
            #expect(h.outbound.contentFrames(for: id, decryptingWith: h.sender) == 0, "\(id) sent no output")
        }
        #expect(Set(h.engine.cancelledIndices) == [1, 2])
        #expect(h.outbound.terminals(for: "streaming") == 0, "the streaming request is untouched")

        h.engine.token(3)
        h.engine.finish(3)
        var answer = ""
        for try await event in owner { if case .content(let text) = event { answer += text } }
        #expect(answer == "a")

        h.engine.token(0)
        h.engine.finish(0)
        #expect(await eventually { h.outbound.completed(for: "streaming") })
        #expect(h.outbound.failure(for: "streaming") == nil)
        #expect(h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 2)
        await h.remove()
    }

    /// With me first off, the owner's request waits its turn, as before: nothing is re-routed.
    @Test func sharedModeLeavesNetworkWorkAlone() async throws {
        let h = try await Self.harness(meFirst: false)
        try await h.network("streaming")
        try await h.network("prefilling")
        try await h.network("queued")
        h.engine.token(0)
        try #require(await eventually { h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 1 })

        let owner = try await h.owner()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.cancelledIndices.isEmpty)
        #expect(h.engine.waiting == [2, 3])
        for id in ["streaming", "prefilling", "queued"] { #expect(h.outbound.terminals(for: id) == 0) }

        h.engine.token(0); h.engine.finish(0)
        h.engine.token(1); h.engine.finish(1)
        #expect(await eventually { h.engine.running.contains(3) })
        h.engine.token(2); h.engine.finish(2)
        h.engine.token(3); h.engine.finish(3)
        var answer = ""
        for try await event in owner { if case .content(let text) = event { answer += text } }
        #expect(answer == "a")
        for id in ["streaming", "prefilling", "queued"] {
            #expect(await eventually { h.outbound.completed(for: id) }, "\(id) completes")
        }
        await h.remove()
    }

    /// A request that sent output never gives way, and one that gave way sends none.
    @Test func outputAndGivingWayExcludeEachOther() {
        let streaming = InferenceCancellationToken()
        #expect(streaming.claimOutput())
        #expect(!streaming.giveWay())
        #expect(!streaming.isCancelled && !streaming.gaveWay)

        let waiting = InferenceCancellationToken()
        #expect(waiting.giveWay())
        #expect(waiting.isCancelled && waiting.gaveWay)
        #expect(!waiting.claimOutput())
        #expect(!waiting.giveWay(), "once")

        let cancelled = InferenceCancellationToken()
        cancelled.cancel()
        #expect(!cancelled.giveWay(), "a request the coordinator cancelled ends as a cancel")
    }
}

extension ProviderLoop {
    /// A coordinator request's terminal reads MLX's allocator: these CPU-only tests skip it.
    func skipTerminalMemoryReadForTesting() { terminalMemoryForTesting = { (0, 0) } }
}

/// Polls `condition` for up to 5 s of real time.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// What the loop sends the coordinator.
final class GiveWayOutbound: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }

    private func messages(for id: String) -> [OutboundMessage] {
        lock.withLock { messages }.filter {
            switch $0 {
            case .inferenceError(let request, _, _), .inferenceComplete(let request, _, _, _, _, _),
                 .inferenceChunk(let request, _, _): return request == id
            default: return false
            }
        }
    }

    func terminals(for id: String) -> Int {
        messages(for: id).filter {
            switch $0 {
            case .inferenceError, .inferenceComplete: return true
            default: return false
            }
        }.count
    }

    func failure(for id: String) -> InferenceFailure? {
        for case .inferenceError(_, let failure, _) in messages(for: id) { return failure }
        return nil
    }

    func completed(for id: String) -> Bool {
        messages(for: id).contains { if case .inferenceComplete = $0 { return true } else { return false } }
    }

    /// The frames that carried generated text.
    func contentFrames(for id: String, decryptingWith receiver: NodeKeyPair) -> Int {
        messages(for: id).filter {
            guard case .inferenceChunk(_, _, let encrypted?) = $0, let raw = try? receiver.decryptPayload(encrypted),
                  let frame = String(data: raw, encoding: .utf8) else { return false }
            return frame.contains(#""content":"a""#)
        }.count
    }
}

/// A queue of `slots` running requests, admitted in arrival order, with no tensors. Each read of its capacity is one
/// engine step. Requests are named by arrival index.
final class GiveWayEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let slots: Int
    private var arrivals: [CBv2Request] = []
    private var streams: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var runningIDs: [CBv2RequestID] = []
    private var waitingIDs: [CBv2RequestID] = []
    private var cancelledIDs: [CBv2RequestID] = []
    private var steps = 0

    init(slots: Int) { self.slots = slots }

    var submittedCount: Int { lock.withLock { arrivals.count } }
    var running: [Int] { lock.withLock { runningIDs.compactMap(index) } }
    var waiting: [Int] { lock.withLock { waitingIDs.compactMap(index) } }
    var cancelledIndices: [Int] { lock.withLock { cancelledIDs.compactMap(index) } }

    private func index(_ id: CBv2RequestID) -> Int? { arrivals.firstIndex { $0.id == id } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            arrivals.append(request)
            streams[request.id] = continuation
            if runningIDs.count < slots { runningIDs.append(request.id) } else { waitingIDs.append(request.id) }
        }
        return stream
    }

    /// The `index`-th request's next token, "a".
    func token(_ index: Int) {
        let events = lock.withLock { streams[arrivals[index].id] }
        events?.yield(.delta(text: "a", tokens: [5], logprobs: nil))
    }

    /// The `index`-th request's end; the next waiting request runs.
    func finish(_ index: Int) {
        let (request, events) = lock.withLock { () -> (CBv2Request, AsyncStream<CBv2Event>.Continuation?) in
            let request = arrivals[index]
            leave(request.id)
            return (request, streams.removeValue(forKey: request.id))
        }
        events?.yield(.finished(reason: .stop, usage: .init(promptTokens: request.promptTokens.count, completionTokens: 1)))
        events?.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        let ended = lock.withLock { () -> (CBv2Request, AsyncStream<CBv2Event>.Continuation)? in
            guard let events = streams.removeValue(forKey: id), let index = index(id) else { return nil }
            cancelledIDs.append(id)
            leave(id)
            return (arrivals[index], events)
        }
        guard let (request, events) = ended else { return }
        events.yield(.finished(reason: .cancelled, usage: .init(promptTokens: request.promptTokens.count, completionTokens: 0)))
        events.finish()
    }

    /// Caller holds the lock.
    private func leave(_ id: CBv2RequestID) {
        waitingIDs.removeAll { $0 == id }
        if let at = runningIDs.firstIndex(of: id) {
            runningIDs.remove(at: at)
            if !waitingIDs.isEmpty { runningIDs.append(waitingIDs.removeFirst()) }
        }
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            steps += 1
            return .init(activeRequests: runningIDs.count, waitingRequests: waitingIDs.count, kvBytesInUse: 0,
                         kvBytesCapacity: 0, activeTokens: 0, stepsExecuted: steps)
        }
    }

    func shutdown() async {
        let open = lock.withLock { () -> [AsyncStream<CBv2Event>.Continuation] in
            defer { streams.removeAll() }
            return Array(streams.values)
        }
        for events in open { events.finish() }
    }
}
#endif
