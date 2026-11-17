import DarkbloomClusterProtocol
import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import NIOCore
import Testing
@testable import ProviderCore

/// The owner's request on this Mac's local API, when requests already running hold the memory it needs, waits for
/// them instead of a 503 at once (`OwnerMemoryWait`), in arrival order and for a bounded time; past it, and for a
/// request larger than the memory holds idle, the 503 says which, and only the second asks for a smaller request
/// (Hermes Agent read the old words, "Lower max_tokens or shorten the prompt", as its 19K-token conversation being
/// too large for a 256K window). A Darkbloom request is refused at once, as before. The pair here is fabricated (no
/// process, model or GPU): its memory holds `servingContextTokens` idle, and its live gate admits a reservation
/// within the room the running requests leave, as a rank's gate does, refusing it otherwise for that request alone.
@Suite("The owner's request waits for the memory running requests hold", .serialized, .timeLimit(.minutes(1)))
struct LocalMemoryWaitTests {
    static let model = "memory-wait/model"

    static func profile() throws -> DistributedResidentExecutionProfile {
        try .init(id: "fabricated-greedy", vocabularySize: 100, maxPromptTokens: 4_095, maxOutputTokens: 4_096,
            maxContextTokens: 4_096, requestTimeout: .seconds(60), supportsLogprobs: true)
    }

    static func bridge(_ pair: MemoryGatedPair,
                       firstToken: DistributedFirstTokenBudgetPolicy? = nil) throws -> EngineV2Bridge {
        try DistributedEngineFactory.makeBridge(owner: pair, expectedIdentity: pair.identity, profile: profile(),
            tokenizer: TokenizerHandle(FixedLengthTokenizer()), eosTokenIDs: [99], firstTokenBudgetPolicy: firstToken)
    }

    /// One owner's request of `prompt` tokens and `maxTokens` straight to the bridge, as the local API submits it,
    /// received at `origin` (nil: when each attempt starts).
    static func ownerRequest(_ bridge: EngineV2Bridge, prompt: Int, maxTokens: Int, wait: OwnerMemoryWait,
                             origin: ContinuousClock.Instant? = nil) async throws -> AsyncStream<GenerationEvent> {
        try await OwnerMemoryWait.$current.withValue(wait) {
            try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: model, messages: [], max_tokens: maxTokens), requestId: UUID().uuidString,
                firstContentDeadline: nil, distributedRequestOrigin: origin)
        }
    }

    /// The completion tokens a stream reported at its end, and its errors.
    static func drain(_ stream: AsyncStream<GenerationEvent>) async -> (tokens: Int, errors: [String]) {
        var tokens = 0, errors: [String] = []
        for await event in stream {
            switch event {
            case .info(_, let completionTokens, _, _): tokens = completionTokens
            case .error(let message): errors.append(message)
            default: break
            }
        }
        return (tokens, errors)
    }

    static func refusal(of error: any Error) -> String? {
        if case MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(let message)? =
            error as? MultiModelBatchSchedulerEngineError { return message }
        return nil
    }

    // MARK: - The queue, the setting and the words

    @Test func theQueueKeepsArrivalOrderAndKeepsAWakeForTheNextPark() async {
        var queue = OwnerMemoryQueue()
        let first = queue.enqueue()!, second = queue.enqueue()!
        #expect(queue.isFirst(first) && !queue.isFirst(second))
        // A wake that comes before the park is kept: the park resumes at once (a lost wake would hang here).
        queue.wakeFirst()
        await withCheckedContinuation { continuation in queue.park(first, continuation) }
        // The first leaving wakes the second, now first: its park resumes at once.
        queue.leave(first)
        #expect(queue.isFirst(second))
        await withCheckedContinuation { continuation in queue.park(second, continuation) }
        queue.leave(second)
        #expect(queue.isEmpty)
        // The queue is bounded as a pair's lane queue is.
        var full = OwnerMemoryQueue()
        for _ in 0 ..< OwnerMemoryWait.maximumWaiting { #expect(full.enqueue() != nil) }
        #expect(full.enqueue() == nil)
    }

    @Test func theOwnersSettingBoundsTheWait() {
        #expect(OwnerMemoryWait.limit(environment: [:]) == .seconds(120))
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: "0"]) == .zero)
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: " 30 "]) == .seconds(30))
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: "600"]) == .seconds(600))
        for invalid in ["-1", "601", "two", "1.5", ""] {
            #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: invalid]) == .seconds(120),
                    "\(invalid)")
        }
    }

    /// `darkbloom start` passes the owner's setting to the launchd provider, so `0` turns the wait off on the service.
    @Test func darkbloomStartPassesTheSettingToTheService() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(OwnerMemoryWait.environmentName))
        #expect(LaunchAgent.passthroughEnvironment(from: [OwnerMemoryWait.environmentName: "0"])[
            OwnerMemoryWait.environmentName] == "0")
    }

    /// Only a request larger than the memory holds with nothing else running reads as too large.
    @Test func aRefusalReadsAsBusyUnlessTheRequestExceedsTheIdleMemory() {
        let busy = [
            EngineV2Bridge.serviceAllowanceExhausted,
            EngineV2Bridge.idleCalibrationRetirementOverdue,
            "token_budget_exhausted: request requires 900 tokens " + EngineV2Bridge.sharedKVNoHeadroom,
            "token_budget_exhausted: slot_capacity_committed (61440 reserved tokens)",
            "token_budget_exhausted: request requires 900 context tokens but only 4096 available on this cluster pair "
                + "now (capacity)",
            DistributedMemoryAbort.message(requestedContextTokens: 6, servingContextTokens: 4, rank: 1),
            OwnerMemoryWait.busyRefusal,
            "token_budget_exhausted: the engine couldn't admit the request within its admission lease",
        ]
        for message in busy { #expect(OwnerMemoryRefusal(refusal: message) == .busy, "\(message)") }
        let exceedsIdle = [
            OwnerMemoryWait.exceedsIdleRefusal,
            "token_budget_exhausted: request_exceeds_slot_capacity (300000 reserved tokens)",
            "token_budget_exhausted: request requires 9000 context tokens but only 4096 available on this cluster "
                + "pair now (capacity)",
            "token_budget_exhausted: request requires 123456 tokens but only 4096 available",
        ]
        for message in exceedsIdle { #expect(OwnerMemoryRefusal(refusal: message) == .exceedsIdle, "\(message)") }
    }

    // MARK: - The pair's bridge

    /// The user's case: the owner's request finds a running request holding the pair's memory. It waits, and starts
    /// as soon as the running one ends, well before its next retry would have come.
    @Test func anOwnersRequestStartsWhenTheRunningRequestGivesItsMemoryBack() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 64)
        let bridge = try Self.bridge(pair)
        pair.holdPrompt = 8
        let running = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 8),
            request: .init(model: Self.model, messages: [], max_tokens: 40))
        #expect(await eventually { pair.reservedPrompts == [8] })
        let wait = OwnerMemoryWait(limit: .seconds(30), retryInterval: .seconds(60))
        let owner = Task { try await Self.ownerRequest(bridge, prompt: 9, maxTokens: 30, wait: wait) }
        #expect(await eventually { pair.attemptedPrompts.filter { $0 == 9 }.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(pair.reservedPrompts == [8], "it waits while the running request holds the memory")
        #expect(await bridge.ownerMemoryWaiters.waiting.count == 1)
        pair.hold.signal()
        #expect(await Self.drain(running).tokens == 40)
        let served = await Self.drain(try await owner.value)
        #expect(served.tokens == 30 && served.errors.isEmpty, "\(served)")
        #expect(pair.reservedPrompts == [8, 9])
        #expect(await bridge.ownerMemoryWaiters.isEmpty)
        await bridge.shutdown()
    }

    /// Nobody overtakes a waiter: a later owner's request queues behind it without asking the pair, and starts after.
    @Test func ownersRequestsStartInArrivalOrder() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let wait = OwnerMemoryWait(limit: .seconds(30), retryInterval: .milliseconds(20))
        let first = Task { try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4, wait: wait) }
        #expect(await eventually { pair.attemptedPrompts.contains(8) })
        let second = Task { try await Self.ownerRequest(bridge, prompt: 9, maxTokens: 4, wait: wait) }
        #expect(await eventually { await bridge.ownerMemoryWaiters.waiting.count == 2 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(!pair.attemptedPrompts.contains(9), "the second never asks while the first waits")
        pair.setRoom(64)
        #expect(await Self.drain(try await first.value).tokens == 4)
        #expect(await Self.drain(try await second.value).tokens == 4)
        #expect(pair.reservedPrompts == [8, 9])
        await bridge.shutdown()
    }

    /// The wait is bounded: past it, the request is refused as busy.
    @Test func anOwnersRequestStillRefusedAfterItsWaitIsRefusedAsBusy() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let start = ContinuousClock.now
        do {
            _ = try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4,
                wait: OwnerMemoryWait(limit: .milliseconds(400), retryInterval: .milliseconds(50)))
            Issue.record("served with no room")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.busyRefusal, "\(error)")
        }
        let waited = ContinuousClock.now - start
        #expect(waited >= .milliseconds(400) && waited < .seconds(5), "\(waited)")
        #expect(pair.attemptedPrompts.count >= 2, "it tried again while it waited")
        #expect(await bridge.ownerMemoryWaiters.isEmpty)
        await bridge.shutdown()
    }

    /// A request larger than the pair's memory holds idle waits for nothing: refused at once, in the words that say
    /// what to change, and no rank is asked.
    @Test func aRequestLargerThanTheIdleMemoryIsRefusedAtOnce() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 64)
        let bridge = try Self.bridge(pair)
        let start = ContinuousClock.now
        do {
            _ = try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 100, wait: OwnerMemoryWait(limit: .seconds(30)))
            Issue.record("served past the idle memory")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.exceedsIdleRefusal, "\(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(pair.attemptedPrompts.isEmpty)
        await bridge.shutdown()
    }

    /// With the wait off, the owner's busy request is refused at once, still in the busy words.
    @Test func withTheWaitOffABusyRequestIsRefusedAtOnce() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        do {
            _ = try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4, wait: OwnerMemoryWait(limit: .zero))
            Issue.record("served with no room")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.busyRefusal, "\(error)")
        }
        #expect(pair.attemptedPrompts == [8])
        await bridge.shutdown()
    }

    /// A Darkbloom request is refused at once, as before, in the pair's own capacity words (the coordinator's
    /// `request_exceeds_node_budget`), so routing moves on.
    @Test func aDarkbloomRequestIsStillRefusedAtOnce() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let start = ContinuousClock.now
        do {
            _ = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 8),
                request: .init(model: Self.model, messages: [], max_tokens: 4), firstContentDeadline: nil)
            Issue.record("served with no room")
        } catch {
            let message = Self.refusal(of: error) ?? ""
            #expect(message.hasPrefix("token_budget_exhausted: request requires 12 context tokens but only 64"),
                    "\(error)")
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
            #expect(failure.statusCode == 503 && failure.errorReason == .requestExceedsNodeBudget)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await bridge.ownerMemoryWaiters.isEmpty)
        await bridge.shutdown()
    }

    /// A client that leaves while its request waits takes it out of the queue.
    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let waiter = Task {
            try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4,
                wait: OwnerMemoryWait(limit: .seconds(30), retryInterval: .seconds(60)))
        }
        #expect(await eventually { await bridge.ownerMemoryWaiters.waiting.count == 1 })
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        #expect(await bridge.ownerMemoryWaiters.isEmpty)
        await bridge.shutdown()
    }

    /// The pair's first-token allowance starts when the wait ends, as after its lane queue: a request that waited
    /// longer than the allowance still starts.
    @Test func thePairsFirstTokenAllowanceStartsAfterTheWait() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair,
            firstToken: try DistributedFirstTokenBudgetPolicy(baseMilliseconds: 1_500, millisecondsPerInputToken: 0))
        let received = ContinuousClock.now
        let owner = Task {
            try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4,
                wait: OwnerMemoryWait(limit: .seconds(30), retryInterval: .milliseconds(50)), origin: received)
        }
        try await Task.sleep(for: .milliseconds(2_500))
        pair.setRoom(64)
        let served = await Self.drain(try await owner.value)
        #expect(served.tokens == 4 && served.errors.isEmpty, "\(served)")
        await bridge.shutdown()
    }

    /// Me first: while the owner's request waits for memory it asks Darkbloom work still queued to give way, as it
    /// does while it waits in the engine's queue (`watchOwnerWait`).
    @Test func aWaitingOwnersRequestAsksDarkbloomWorkToGiveWay() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let asked = WaitCounter()
        let owner = Task {
            try await MeFirstOwnerRequest.$makeRoom.withValue({ asked.add() }) {
                try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4,
                    wait: OwnerMemoryWait(limit: .seconds(30), retryInterval: .milliseconds(20)))
            }
        }
        #expect(await eventually { asked.value >= 2 }, "it asked \(asked.value) times")
        pair.setRoom(64)
        #expect(await Self.drain(try await owner.value).tokens == 4)
        await bridge.shutdown()
    }

    /// A loop exit's continuation is the answer of a request already served (one Mac: a pair serves none): it never
    /// waits, and gets the refusal as it is.
    @Test func aLoopExitsContinuationNeverWaits() async throws {
        let mac = Self.oneMac(room: 100 << 20)
        #expect(await mac.budget.reserveBytes(requestID: "running", bytes: 80 << 20))
        let start = ContinuousClock.now
        do {
            _ = try await EngineAdmissionPriority.$current.withValue(1) {
                try await Self.ownerRequest(mac.bridge, prompt: 8, maxTokens: 40,
                    wait: OwnerMemoryWait(limit: .seconds(30)))
            }
            Issue.record("served with no room")
        } catch {
            #expect(Self.refusal(of: error)?.hasSuffix(EngineV2Bridge.sharedKVNoHeadroom) == true, "\(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await mac.bridge.ownerMemoryWaiters.isEmpty)
        await mac.bridge.shutdown()
    }

    /// A `cluster local` response binds each attempt's first-token deadline: a refused attempt's deadline and timer
    /// end before the next attempt binds its own; nothing is unbound once admission finished or the client left.
    @Test func aRefusedAdmissionUnbindsItsDeadlineForTheNextAttempt() async throws {
        let response = DistributedHTTPResponse()
        let cancels = WaitCounter()
        try response.bind(deadline: .now.advanced(by: .milliseconds(50)), cancel: { cancels.add() })
        response.unbindRefusedAdmission()
        #expect(response.selectedDeadline == nil)
        let later = ContinuousClock.now.advanced(by: .seconds(30))
        try response.bind(deadline: later, cancel: { cancels.add() })
        #expect(response.selectedDeadline == later)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!response.deadlineExpired && cancels.value == 0, "the refused attempt's timer fired")
        response.applyPendingCancellation()
        response.unbindRefusedAdmission()
        #expect(throws: CancellationError.self) { try response.bind(deadline: later, cancel: {}) }
        let left = DistributedHTTPResponse()
        try left.bind(deadline: later, cancel: {})
        left.disconnect()
        left.unbindRefusedAdmission()
        #expect(throws: CancellationError.self) { try left.bind(deadline: later, cancel: {}) }
    }

    /// Whether a request this Mac can't start for memory waits here, by route: unless the route reaches Macs that may
    /// take it now (`LocalRouter.waitsHereForMemory`). The count is the coordinator's view of the owner's Macs serving
    /// the model; nil is a coordinator that can't say.
    @Test func aRequestWaitsHereUnlessItsRouteReachesAnotherMac() async throws {
        func waits(_ route: LocalSettings.Route, key: String? = "sk-memory-wait-fixture", coordinatorWork: Bool = false,
                   count: Int? = 0) async -> Bool {
            let upstream = RouterStubUpstream { request in
                guard request.method == "GET", request.url.path == "/v1/models/\(Self.model)" else {
                    return .json(200, "{}")
                }
                switch count {
                case nil: return .json(500, #"{"error":{"message":"internal"}}"#)
                case 0?: return .json(404, #"{"error":{"code":"model_not_found"}}"#)
                case let count?:
                    return .json(200, #"{"id":"\#(Self.model)","metadata":{"provider_count":\#(count)}}"#)
                }
            }
            let router = LocalRouter(config: LocalRouterConfig(
                settings: LocalSettings(route: route), upstreamBaseURL: URL(string: "http://coordinator.invalid")!,
                takesCoordinatorWork: coordinatorWork, accountKeys: CountingAccountKeyStore(key),
                makeTransport: { upstream }, log: { _ in }), localModels: { [Self.model] })
            return await router.waitsHereForMemory(model: Self.model)
        }
        #expect(await waits(.thisMac))
        #expect(await waits(.myMacs, key: nil, count: 2), "no account key: requests stay on this Mac")
        #expect(await !waits(.myMacsFirst), "my-macs-first reaches the network")
        #expect(await waits(.myMacs, count: 0))
        #expect(await !waits(.myMacs, count: 1), "another of the owner's Macs serves it")
        #expect(await waits(.myMacs, count: nil))
        #expect(await waits(.myMacs, coordinatorWork: true, count: 1), "the one serving it is this Mac")
        #expect(await !waits(.myMacs, coordinatorWork: true, count: 2))
    }

    // MARK: - One Mac

    /// One Mac's contiguous slot whose shared KV budget holds `room` bytes with nothing else running, a MiB a token.
    static func oneMac(room: UInt64) -> (bridge: EngineV2Bridge, engine: OutputRecordingEngine,
                                         budget: GlobalKVCacheBudget) {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            .init(total: (2 << 30) + room, active: 0, cache: 0, systemAvailable: .max)
        })
        let engine = OutputRecordingEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: TokenizerHandle(FixedLengthTokenizer()),
            eosTokenIds: [], defaultMaxTokens: 1_000, defaultMaxTokensContextLimit: 4_096, maxConcurrentRequests: 4,
            kvBytesPerToken: 1 << 20, kvBudget: budget)
        return (bridge, engine, budget)
    }

    /// On one Mac, the owner's request waits while another request's reservation takes the shared budget's room and
    /// starts once it is released; one the budget couldn't hold with every request reservation released is refused at
    /// once, though a reservation is held.
    @Test func onOneMacTheOwnersRequestWaitsForTheSharedBudget() async throws {
        let mac = Self.oneMac(room: 100 << 20)
        #expect(await mac.budget.reserveBytes(requestID: "running", bytes: 80 << 20))
        let wait = OwnerMemoryWait(limit: .seconds(30), retryInterval: .milliseconds(20))
        let start = ContinuousClock.now
        do {
            _ = try await Self.ownerRequest(mac.bridge, prompt: 8, maxTokens: 200, wait: wait)
            Issue.record("served past the whole budget")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.exceedsIdleRefusal, "\(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        let owner = Task { try await Self.ownerRequest(mac.bridge, prompt: 8, maxTokens: 40, wait: wait) }
        #expect(await eventually { await mac.bridge.ownerMemoryWaiters.waiting.count == 1 })
        #expect(mac.engine.submittedOutputs.isEmpty)
        await mac.budget.release(requestID: "running")
        _ = await Self.drain(try await owner.value)
        #expect(mac.engine.submittedOutputs == [40])
        await mac.bridge.shutdown()
    }

    /// Diffusion Gemma's native block engine refuses a request it can't take now in the figures a paged engine uses
    /// only for one that can never fit. The owner's request that would fit its idle capacity waits for the requests
    /// it holds, and starts when they end; one larger than its whole capacity is refused at once.
    @Test func aNativeBlockEnginesBusyRefusalWaits() async throws {
        let latch = WaitLatch()
        let tokenizer = FixedLengthTokenizer()
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 200, shutdownGraceSeconds: 0,
            loopConfig: .init(stepTimeout: 60, watchdogInterval: 0.01),
            reservationForRequest: { request in request.maxTokens > 100 ? 500 : 100 },
            makeSession: { _, cancellation in HeldNativeSession(latch: latch, cancellation: cancellation) })
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 1 << 30)
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 2, maxConcurrentRequests: 8, kvBytesPerToken: 1, kvBudget: budget)
        defer { latch.open() }
        let request = ChatCompletionRequest(model: Self.model, messages: [], temperature: 1, max_tokens: 2)
        let held = [
            await bridge.submitTokenized(promptTokens: [1], request: request, requestId: "held-1", cacheEnabled: false),
            await bridge.submitTokenized(promptTokens: [1], request: request, requestId: "held-2", cacheEnabled: false),
        ]
        let running = held.map { stream in Task { await Self.drain(stream) } }
        #expect(await eventually { engine.capacity().activeRequests + engine.capacity().waitingRequests == 2 })
        let wait = OwnerMemoryWait(limit: .seconds(30), retryInterval: .milliseconds(20))
        do {
            _ = try await Self.ownerRequest(bridge, prompt: 1, maxTokens: 300, wait: wait)
            Issue.record("served past the engine's whole capacity")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.exceedsIdleRefusal, "\(error)")
        }
        let owner = Task { try await Self.ownerRequest(bridge, prompt: 1, maxTokens: 2, wait: wait) }
        #expect(await eventually { await bridge.ownerMemoryWaiters.waiting.count == 1 }, "refused at once while busy")
        latch.open()
        for task in running { _ = await task.value }
        let served = await Self.drain(try await owner.value)
        #expect(served.errors.isEmpty, "\(served)")
        await bridge.shutdown()
    }

    // MARK: - The local API

    /// This Mac's API over the pair's bridge: the status, `Retry-After` and the error message of a chat request whose
    /// prompt renders to `prompt` tokens, and how long it took.
    static func answer(_ bridge: EngineV2Bridge, prompt: Int, maxTokens: Int, stream: Bool, limit: Duration)
        async throws -> (status: Int, retryAfter: String?, message: String?, body: String, took: Duration) {
        let handle = TokenizerHandle(FixedLengthTokenizer(count: prompt))
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                .init(tokenizer: handle, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                      modelType: nil, container: nil, isVLM: false, engineV2Bridge: bridge,
                      visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { _ in .init(tokenizer: handle, modelType: nil) },
            availableModels: { [Self.model] }, mtpSlots: { [] }, memoryWaitLimit: limit)
        let body = #"{"model":"\#(Self.model)","stream":\#(stream),"max_tokens":\#(maxTokens),"#
            + #""messages":[{"role":"user","content":"hi"}]}"#
        let start = ContinuousClock.now
        let (status, retryAfter, text) = try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: ByteBuffer(string: body))
            return (response.status.code, response.headers[.retryAfter], String(buffer: response.body))
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return (status, retryAfter, (json?["error"] as? [String: Any])?["message"] as? String, text,
                ContinuousClock.now - start)
    }

    /// Streamed or not, a busy pair's 503 comes only after the wait, says the Mac is at capacity with nothing about
    /// the request to change, and carries `Retry-After`.
    @Test(arguments: [false, true])
    func thisMacsAPISaysBusyAfterTheWait(stream: Bool) async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let answer = try await Self.answer(bridge, prompt: 8, maxTokens: 4, stream: stream, limit: .milliseconds(500))
        #expect(answer.status == 503, "\(answer.body.prefix(300))")
        #expect(answer.message == memoryBusyWords)
        #expect(answer.retryAfter == "10")
        #expect(!answer.body.contains("max_tokens") && !answer.body.contains("prompt") && !answer.body.contains("data:"))
        #expect(answer.took >= .milliseconds(500))
        await bridge.shutdown()
    }

    /// The owner's request through this Mac's API waits for the room and is served.
    @Test(arguments: [false, true])
    func thisMacsAPIServesARequestOnceTheMemoryFrees(stream: Bool) async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let opener = Task {
            try await Task.sleep(for: .milliseconds(300))
            pair.setRoom(64)
        }
        let answer = try await Self.answer(bridge, prompt: 8, maxTokens: 4, stream: stream, limit: .seconds(30))
        _ = try await opener.value
        #expect(answer.status == 200, "\(answer.body.prefix(300))")
        #expect(answer.message == nil)
        #expect(pair.reservedPrompts == [8])
        await bridge.shutdown()
    }

    /// Only a request larger than the memory holds idle is told to change: at once, before any SSE header.
    @Test(arguments: [false, true])
    func thisMacsAPIAsksForASmallerRequestOnlyWhenItCanNeverFit(stream: Bool) async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 64)
        let bridge = try Self.bridge(pair)
        let answer = try await Self.answer(bridge, prompt: 8, maxTokens: 100, stream: stream, limit: .seconds(30))
        #expect(answer.status == 503, "\(answer.body.prefix(300))")
        #expect(answer.message == memoryExceedsIdleWords)
        #expect(answer.retryAfter == nil)
        #expect(answer.took < .seconds(5))
        await bridge.shutdown()
    }
}

/// A pair whose two ranks' memory holds `servingContextTokens` with nothing running, the context the engine checks a
/// request against before asking the ranks, and `room` tokens now: a reservation within the room takes its tokens until
/// the request's resources are released; one past it is refused for that request alone, as a rank's live gate refuses.
/// A request whose prompt has `holdPrompt` tokens waits for `hold` before its first token.
final class MemoryGatedPair: DistributedResidentExecutionOwner, @unchecked Sendable {
    let identity = ScriptedPairOwner().identity
    let servingContextTokens: Int
    let hold = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var room: Int
    private var attempts: [Int] = []
    private var reserved: [Int] = []
    private var heldPrompt: Int?
    var concurrentRequests: Int { 4 }

    init(servingContextTokens: Int, room: Int) {
        self.servingContextTokens = servingContextTokens
        self.room = room
    }

    var holdPrompt: Int? {
        get { lock.withLock { heldPrompt } }
        set { lock.withLock { heldPrompt = newValue } }
    }
    /// The prompt length of every reservation asked for, in order.
    var attemptedPrompts: [Int] { lock.withLock { attempts } }
    /// The prompt length of every reservation admitted, in order.
    var reservedPrompts: [Int] { lock.withLock { reserved } }
    func setRoom(_ tokens: Int) { lock.withLock { room = tokens } }

    func readiness() -> DistributedResidentReadiness? {
        .init(identity: identity, profileID: "fabricated-greedy", requestCapacityBytes: 1 << 30,
              servingContextTokens: servingContextTokens)
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        let tokens = request.promptTokens.count + request.maxTokens
        let held = try lock.withLock { () -> Bool in
            attempts.append(request.promptTokens.count)
            guard tokens <= room else {
                throw DistributedEngineError.refusedForCapacity(requestedContextTokens: tokens,
                    servingContextTokens: servingContextTokens, reason: "capacity")
            }
            room -= tokens
            reserved.append(request.promptTokens.count)
            return request.promptTokens.count == heldPrompt
        }
        return MemoryGatedLease(identity: identity, requestID: request.id, hold: held ? hold : nil) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.room += tokens }
        }
    }
    func shutdown() async {}
}

/// One request on `MemoryGatedPair`: tokens until the engine declines one, then retirement; its tokens go back to the
/// pair's room when its resources are released.
final class MemoryGatedLease: DistributedResidentRequestLease, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let requestID: CBv2RequestID
    let reservedBytes = 64
    var bytesInUse: Int { 0 }
    private let retired = DistributedRetirementLatch()
    private let hold: DispatchSemaphore?
    private let onRelease: @Sendable () -> Void

    init(identity: DistributedResidentIdentity, requestID: CBv2RequestID, hold: DispatchSemaphore?,
         onRelease: @escaping @Sendable () -> Void) {
        self.identity = identity; self.requestID = requestID; self.hold = hold; self.onRelease = onRelease
    }
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws {
        DispatchQueue.global().async { [retired, hold] in
            hold?.wait()
            var token = 5
            while emit(.token(token)) { token += 1 }
            retired.complete()
        }
    }
    func cancel() { retired.complete() }
    func waitUntilRetired() async { await retired.wait() }
    func releaseResources() { onRelease() }
}

/// Counts calls from any task.
final class WaitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// Holds native sessions until it is opened; stays open.
final class WaitLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while !isOpen { condition.wait() }
    }
    func open() {
        condition.lock(); defer { condition.unlock() }
        isOpen = true
        condition.broadcast()
    }
}

/// A native block session that prefills, waits for `latch` before its first token, then stops at the token limit.
final class HeldNativeSession: CBv2NativeBlockSession, @unchecked Sendable {
    let latch: WaitLatch
    let cancellation: CBv2NativeBlockCancellation
    var index = 0, generatedTokenCount = 0
    var retainedBytes: Int { 64 }
    var activeTokenCount: Int { 1 + generatedTokenCount }
    init(latch: WaitLatch, cancellation: CBv2NativeBlockCancellation) {
        self.latch = latch; self.cancellation = cancellation
    }
    func cancel() {}
    func advanceNative() throws -> CBv2NativeBlockStep {
        defer { index += 1 }
        if index == 0 { return .prefill(computedTokens: 1, complete: true) }
        latch.wait()
        if cancellation.isCancelled { throw CancellationError() }
        generatedTokenCount += 1
        return .committed(tokens: [64 + index], stopToken: nil, finishReason: index >= 2 ? .length : nil)
    }
}

/// Polls `condition` every 10 ms for up to 5 s.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< 500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
