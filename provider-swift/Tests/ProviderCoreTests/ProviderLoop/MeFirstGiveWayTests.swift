import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

#if DEBUG
/// Me first re-routes rather than preempts. While the owner's request waits for this Mac's engine, each Darkbloom request
/// still queued for it ends with the typed drain refusal (`capacity`, 503, `draining`). The coordinator then serves it on
/// another Mac, or answers a retryable "busy" when no Mac has room, with no health strike against this one. A Darkbloom
/// request the engine has admitted, in its prompt or streaming, keeps running and finishes. Shared mode changes nothing.
/// The engine is a queue with no tensors; the network requests travel the encrypted coordinator path, the owner's the
/// local engine's.
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
            try await send(id)
            try #require(await eventually { engine.submittedCount == submitted + 1 }, "\(id) reached the engine")
        }

        /// The coordinator's frame for a Darkbloom request, through its handler.
        func send(_ id: String) async throws {
            let body = try JSONSerialization.data(withJSONObject: [
                "model": MeFirstGiveWayTests.model, "messages": [["role": "user", "content": "fixture"]],
                "max_tokens": 8, "stream": true, "reasoning_parser": "none",
            ])
            let encrypted = try sender.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: body)
            await loop.handleInferenceRequest(requestId: id, ciphertext: encrypted,
                senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil,
                authenticatedCacheScope: "give-way-tenant", send: SendHandle(outbound.record))
        }

        /// The drain refusal, the only terminal `id` got.
        func gaveWay(_ id: String) -> Bool {
            let refusal = outbound.failure(for: id)
            return outbound.terminals(for: id) == 1 && refusal?.code == .capacity && refusal?.statusCode == 503
                && refusal?.errorReason == .draining
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

    static func harness(meFirst: Bool, slots: Int = 2, manualSteps: Bool = false) async throws -> Harness {
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
        let engine = GiveWayEngine(slots: slots, manualSteps: manualSteps)
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
    /// request waits too. Only the queued one is re-routed: the one in its prompt keeps its work, as the streaming one
    /// does. The owner's request runs when one of them finishes.
    @Test func onlyQueuedNetworkWorkGivesWayToALocalRequest() async throws {
        let h = try await Self.harness(meFirst: true)
        try await h.network("streaming")
        try await h.network("prefilling")
        try await h.network("queued")
        #expect(h.engine.waiting == [2])
        h.engine.token(0)
        try #require(await eventually { h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 1 })

        let owner = try await h.owner()
        #expect(await eventually { h.gaveWay("queued") }, "the queued request gives way")
        #expect(h.outbound.contentFrames(for: "queued", decryptingWith: h.sender) == 0, "and sent no output")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.engine.cancelledIndices == [2], "the owner's later asks re-route nothing more")
        #expect(h.engine.waiting == [3], "the owner's request waits for the work the engine admitted")
        for id in ["streaming", "prefilling"] { #expect(h.outbound.terminals(for: id) == 0, "\(id) is untouched") }

        h.engine.token(1)
        h.engine.finish(1)
        #expect(await eventually { h.engine.running.contains(3) }, "the owner's request runs once the prompt's answer ends")
        h.engine.token(3)
        h.engine.finish(3)
        var answer = ""
        for try await event in owner { if case .content(let text) = event { answer += text } }
        #expect(answer == "a")
        #expect(await eventually { h.outbound.completed(for: "prefilling") })
        #expect(h.outbound.failure(for: "prefilling") == nil)

        h.engine.token(0)
        h.engine.finish(0)
        #expect(await eventually { h.outbound.completed(for: "streaming") })
        #expect(h.outbound.failure(for: "streaming") == nil)
        #expect(h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 2)
        await h.remove()
    }

    /// A Darkbloom request the engine admitted keeps its work while the owner's request asks; once the engine puts it
    /// back in its queue (preempted for memory, its prompt's work gone), it gives way at the owner's next look.
    @Test func aRequestTheEnginePutsBackInItsQueueGivesWayAtTheOwnersNextLook() async throws {
        let h = try await Self.harness(meFirst: true)
        try await h.network("streaming")
        try await h.network("prefilling")
        h.engine.token(0)
        try #require(await eventually { h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 1 })

        let owner = try await h.owner()
        let looks = h.engine.capacityReads
        #expect(await eventually { h.engine.capacityReads >= looks + 10 }, "the owner's request asked several times")
        #expect(h.outbound.terminals(for: "prefilling") == 0, "admitted, it keeps its work")

        h.engine.preempt(1)
        #expect(await eventually { h.gaveWay("prefilling") }, "back in the queue, it gives way")
        #expect(h.engine.cancelledIndices == [1])
        h.engine.token(0)
        h.engine.finish(0)
        #expect(await eventually { h.engine.running == [2] }, "the owner's request runs once the streaming one ends")
        h.engine.token(2)
        h.engine.finish(2)
        for try await _ in owner {}
        #expect(await eventually { h.outbound.completed(for: "streaming") })
        #expect(h.outbound.failure(for: "streaming") == nil)
        await h.remove()
    }

    /// A request that gives way while its handler still admits it ends with the one drain refusal and never reaches the
    /// engine: right after its token is registered, when the give-way also cancelled it (the handler's first exit), and
    /// when only its token says so as its stream would start (the last exit).
    @Test(arguments: [true, false])
    func aRequestThatGivesWayInItsHandlerEndsWithOneRefusalAndNoTask(cancelled: Bool) async throws {
        let h = try await Self.harness(meFirst: true)
        let loop = h.loop
        await loop.setAfterTokenRegisteredForTesting { id in
            if cancelled {
                await loop.giveWayToOwner(modelId: Self.model)
            } else {
                _ = await loop.cancellationRegistry.token(for: id)?.giveWay()
            }
        }
        try await h.send("admitting")
        #expect(h.gaveWay("admitting"), "one terminal, the drain refusal")
        #expect(h.engine.submittedCount == 0, "it never reached the engine")
        #expect(await !loop.hasInflightTaskForTesting("admitting"), "and has no task")
        if !cancelled { await loop.handleCancellation(requestId: "admitting", receivedFromCoordinator: false) }
        await h.remove()
    }

    /// The owner's request asks only once it has waited across two engine steps, so one the engine admits sooner never
    /// re-routes anything. Here a Darkbloom request accepted before the pause is still in its handler, queued, and would
    /// give way if asked; the engine's steps move only when the test says.
    @Test func anOwnersRequestTheEngineAdmitsWithinTwoStepsNeverAsks() async throws {
        let h = try await Self.harness(meFirst: true, slots: 1, manualSteps: true)
        try await h.network("running")
        let gate = GiveWayGate()
        let loop = h.loop
        await loop.setAfterTokenRegisteredForTesting { id in if id == "queued" { await gate.wait() } }
        let queued = Task { try await h.send("queued") }
        try #require(await eventually { gate.isWaiting }, "the queued request is in its handler")

        let owner = try await h.owner()
        let looks = h.engine.capacityReads
        #expect(await eventually { h.engine.capacityReads >= looks + 3 }, "the owner's request looked while it waited")
        h.engine.token(0)
        h.engine.finish(0)
        #expect(await eventually { h.engine.running == [1] }, "the owner's request runs, no step having passed")
        h.engine.advanceSteps(4)
        let admittedLooks = h.engine.capacityReads
        #expect(await eventually { h.engine.capacityReads >= admittedLooks + 3 }, "it looks on until its first token")
        #expect(await loop.cancellationRegistry.token(for: "queued")?.gaveWay == false, "nothing gave way")

        h.engine.token(1)
        h.engine.finish(1)
        for try await _ in owner {}
        gate.open()
        try await queued.value
        try #require(await eventually { h.engine.submittedCount == 3 }, "the queued request reaches the engine")
        h.engine.token(2)
        h.engine.finish(2)
        #expect(await eventually { h.outbound.completed(for: "queued") }, "and is served here")
        #expect(h.outbound.failure(for: "queued") == nil)
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
    func setAfterTokenRegisteredForTesting(_ hook: @escaping @Sendable (String) async -> Void) {
        afterTokenRegisteredForTesting = hook
    }
    func hasInflightTaskForTesting(_ id: String) -> Bool { inflightTasks[id] != nil }
}

/// Holds whoever waits on it until the test opens it.
final class GiveWayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in woken { continuation.resume() }
    }
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
/// engine step, unless the steps are `manualSteps`, which move only by `advanceSteps`. Requests are named by arrival
/// index.
final class GiveWayEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var slots: Int
    private let manualSteps: Bool
    private var reads = 0
    private var arrivals: [CBv2Request] = []
    private var streams: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var runningIDs: [CBv2RequestID] = []
    private var waitingIDs: [CBv2RequestID] = []
    private var cancelledIDs: [CBv2RequestID] = []
    private var steps = 0

    init(slots: Int, manualSteps: Bool = false) {
        self.slots = slots
        self.manualSteps = manualSteps
    }

    var submittedCount: Int { lock.withLock { arrivals.count } }
    var capacityReads: Int { lock.withLock { reads } }
    func advanceSteps(_ count: Int) { lock.withLock { steps += count } }
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

    /// The `index`-th request, running, goes back to the front of the queue, as when the engine preempts one for
    /// memory; the engine runs one request fewer from then on.
    func preempt(_ index: Int) {
        lock.withLock {
            let id = arrivals[index].id
            runningIDs.removeAll { $0 == id }
            waitingIDs.insert(id, at: 0)
            slots -= 1
        }
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
            if !waitingIDs.isEmpty, runningIDs.count < slots { runningIDs.append(waitingIDs.removeFirst()) }
        }
    }

    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            reads += 1
            if !manualSteps { steps += 1 }
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
