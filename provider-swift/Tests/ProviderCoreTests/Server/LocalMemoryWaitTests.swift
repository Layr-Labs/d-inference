import DarkbloomClusterProtocol
import Foundation
import HTTPTypes
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

    /// The completion tokens a stream reported at its end, and its errors (a typed terminal's cause among them).
    static func drain(_ stream: AsyncStream<GenerationEvent>) async -> (tokens: Int, errors: [String]) {
        var tokens = 0, errors: [String] = []
        for await event in stream {
            switch event {
            case .info(_, let completionTokens, _, _): tokens = completionTokens
            case .error(let message): errors.append(message)
            case .terminal(let cause, _, _, _): errors.append(cause.rawValue)
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

    @Test func aGLMRequestWaitsForItsShareToGrowBeforeItStarts() async throws {
        let engine = InertStubEngine(kvBytesCapacity: 40)
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.model,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [], kvBytesPerToken: 1)
        await bridge.installGLMSoloGrant { 100 }
        let attempts = WaitCounter()
        let stream = try await bridge.submittingOwnerRequest(
            OwnerMemoryWait(limit: .seconds(2), retryInterval: .milliseconds(10)),
            model: Self.model, worstCaseTokens: 80, origin: nil
        ) { _, _ in
            attempts.add()
            guard engine.capacity().kvBytesCapacity >= 80 else {
                // Model retirement restores the grant, but this attempt still saw the smaller one.
                engine.updateKVBytesCapacity(100)
                throw EngineV2Bridge.glm5NextSlotRefusal(neverFits: true, reservedTokens: 80)
            }
            return AsyncStream { $0.finish() }
        }
        _ = await Self.drain(stream)
        #expect(attempts.value == 2)
        // An extra byte past the solo admission watermark cannot be recovered by waiting.
        let refusal = EngineV2Bridge.glm5NextSlotRefusal(neverFits: true, reservedTokens: 96)
        #expect(await bridge.ownerMemoryRefusal(refusal, worstCaseTokens: 96) == .exceedsIdle)
        await bridge.shutdown()
    }

    /// With the shared-grant wait off, the same request is refused at once in the larger-than-memory words, after
    /// one attempt and without queueing, as 0.10.17 refused it.
    @Test func withTheSharedGrantWaitOffTheRequestIsRefusedAtOnceAsBefore() async throws {
        let engine = InertStubEngine(kvBytesCapacity: 40)
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.model,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [], kvBytesPerToken: 1)
        let quoted = WaitCounter()
        await bridge.installGLMSoloGrant(environment: [OwnerMemoryWait.sharedGrantWaitEnvironmentName: "0"]) {
            quoted.add()
            return 100
        }
        let attempts = WaitCounter()
        let start = ContinuousClock.now
        do {
            _ = try await bridge.submittingOwnerRequest(
                OwnerMemoryWait(limit: .seconds(5), retryInterval: .milliseconds(10)),
                model: Self.model, worstCaseTokens: 80, origin: nil
            ) { _, _ in
                attempts.add()
                throw EngineV2Bridge.glm5NextSlotRefusal(neverFits: true, reservedTokens: 80)
            }
            Issue.record("served without room")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.exceedsIdleRefusal)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(attempts.value == 1 && quoted.value == 0)
        #expect(await bridge.ownerMemoryWaiters.isEmpty)
        let refusal = EngineV2Bridge.glm5NextSlotRefusal(neverFits: true, reservedTokens: 80)
        #expect(await bridge.ownerMemoryRefusal(refusal, worstCaseTokens: 80) == .exceedsIdle)
        await bridge.shutdown()
    }

    @Test(arguments: [false, true])
    func aSharedGrantWaitIsBoundedBehindAnotherOwner(peerLoadsLater: Bool) async throws {
        let bridge = EngineV2Bridge(engine: InertStubEngine(kvBytesCapacity: 40), modelId: Self.model,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [], kvBytesPerToken: 1)
        let quoted = WaitCounter()
        let peer = WaitCounter()
        if !peerLoadsLater { peer.add() }
        await bridge.installGLMSoloGrant {
            let available = peer.value > 0
            quoted.add()
            return available ? 100 : nil
        }
        let head = Task {
            try await bridge.submittingOwnerRequest(OwnerMemoryWait(limit: .seconds(5)),
                model: Self.model, worstCaseTokens: 80, origin: nil) { _, _ in
                    throw EngineV2Bridge.glm5NextSlotRefusal(neverFits: false, reservedTokens: 80)
                }
        }
        #expect(await eventually { await bridge.ownerMemoryWaiters.waiting.count == 1 })
        let shrink = Task {
            if peerLoadsLater {
                #expect(await eventually { quoted.value > 0 })
                peer.add()
                await bridge.updateKVBytesCapacity(20)
            }
        }
        do {
            _ = try await bridge.submittingOwnerRequest(OwnerMemoryWait(sharedGrantLimit: .milliseconds(40)),
                model: Self.model, worstCaseTokens: 80, origin: nil) { _, _ in
                    Issue.record("the follower reached admission while the head still waited")
                    return AsyncStream { $0.finish() }
                }
            Issue.record("the follower did not time out")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.busyRefusal)
        }
        #expect(await bridge.ownerMemoryWaiters.waiting.count == 1)
        await shrink.value
        head.cancel()
        _ = await head.result
        await bridge.shutdown()
    }

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

    /// The owner's request waits as long as it takes by default; the owner's setting or the request's own header bounds
    /// it, the shorter of the two when both name one.
    @Test func theWaitIsUnboundedUnlessTheOwnerOrTheRequestBoundsIt() async {
        #expect(OwnerMemoryWait().limit == nil)
        #expect(OwnerMemoryWait.limit(environment: [:]) == nil)
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: "0"]) == .zero)
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: " 30 "]) == .seconds(30))
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: "600"]) == .seconds(600))
        #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: "3600"]) == .seconds(3600))
        for invalid in ["-1", "two", "1.5", ""] {
            #expect(OwnerMemoryWait.limit(environment: [OwnerMemoryWait.environmentName: invalid]) == nil, "\(invalid)")
        }
        #expect(OwnerMemoryWait.requestLimit(header: nil) == nil)
        #expect(OwnerMemoryWait.requestLimit(header: "0") == .zero)
        #expect(OwnerMemoryWait.requestLimit(header: " 5 ") == .seconds(5))
        for invalid in ["-3", "soon", "2.5", ""] { #expect(OwnerMemoryWait.requestLimit(header: invalid) == nil) }
        let unbounded = OwnerMemoryWait(limit: nil), owners = OwnerMemoryWait(limit: .seconds(30))
        #expect(unbounded.effectiveLimit == nil && owners.effectiveLimit == .seconds(30))
        OwnerMemoryWait.$requestLimit.withValue(.seconds(2)) {
            #expect(unbounded.effectiveLimit == .seconds(2) && owners.effectiveLimit == .seconds(2))
        }
        OwnerMemoryWait.$requestLimit.withValue(.seconds(90)) { #expect(owners.effectiveLimit == .seconds(30)) }
        let waitsAtZero = await OwnerMemoryWait.$requestLimit.withValue(.zero) {
            await unbounded.waits(model: Self.model)
        }
        #expect(!waitsAtZero, "a request that asks for no wait never waits")
    }

    /// `darkbloom start` passes the owner's settings to the launchd provider, so `0` turns each off on the service.
    @Test func darkbloomStartPassesTheSettingsToTheService() {
        for name in [OwnerMemoryWait.environmentName, OwnerMemoryWait.firstTokenWaitEnvironmentName,
                     OwnerMemoryWait.sharedGrantWaitEnvironmentName] {
            #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(name), "\(name)")
            #expect(LaunchAgent.passthroughEnvironment(from: [name: "0"])[name] == "0", "\(name)")
        }
        #expect(OwnerMemoryWait.waitsForFirstToken(environment: [:]))
        for off in ["0", " off ", "False", "no"] {
            #expect(!OwnerMemoryWait.waitsForFirstToken(environment: [OwnerMemoryWait.firstTokenWaitEnvironmentName: off]))
        }
        #expect(OwnerMemoryWait.waitsForFirstToken(environment: [OwnerMemoryWait.firstTokenWaitEnvironmentName: "1"]))
        let shared = OwnerMemoryWait.sharedGrantWaitEnvironmentName
        #expect(OwnerMemoryWait.waitsForSharedGrant(environment: [:]))
        for off in ["0", " off ", "False", "no"] { #expect(!OwnerMemoryWait.waitsForSharedGrant(environment: [shared: off])) }
        for on in ["1", "yes", "on", ""] { #expect(OwnerMemoryWait.waitsForSharedGrant(environment: [shared: on])) }
    }

    /// The busy 503's words for each setting: on, the default words; off, 0.10.17's.
    @Test func theBusyWordsFollowTheSharedGrantSetting() {
        #expect(LocalMemoryRefusal.busy(waitsForSharedGrant: true) == memoryBusyWords)
        #expect(LocalMemoryRefusal.busy(waitsForSharedGrant: false)
            == "This Mac is at capacity: requests already running are using the memory this request needs. "
                + "Retry in a moment, when they finish.")
        #expect(LocalMemoryRefusal.busy == memoryBusyWords, "the default is on")
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
        #expect(ContinuousClock.now - start < .seconds(5))
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
        #expect(ContinuousClock.now - start < .seconds(5))
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

    /// On a pair, the owner's request has no first-token limit: behind another request's long prompt (the pair
    /// prefills one prompt at a time) or on a pair slow after a long idle, it waits for its first token and is served,
    /// where the pair's first-token allowance ended it ("Response generation failed", on a DevNet pair, 2026-11-17). A
    /// Darkbloom request keeps the allowance, and `DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0` gives it back to the owner's.
    @Test func anOwnersRequestOnAPairWaitsForItsFirstToken() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 64)
        let bridge = try Self.bridge(pair,
            firstToken: try DistributedFirstTokenBudgetPolicy(baseMilliseconds: 300, millisecondsPerInputToken: 0))
        /// A request whose first token comes 2 s after it starts, past its 300 ms allowance with room to spare.
        func late(prompt: Int, _ submit: () async throws -> AsyncStream<GenerationEvent>) async throws
            -> (tokens: Int, errors: [String]) {
            pair.holdPrompt = prompt
            let reader = Task { [stream = try await submit()] in await Self.drain(stream) }
            try await Task.sleep(for: .seconds(2))
            pair.hold.signal()
            return await reader.value
        }
        let owner = try await late(prompt: 8) {
            try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4, wait: OwnerMemoryWait(limit: .seconds(30)))
        }
        #expect(owner.tokens == 4 && owner.errors.isEmpty, "\(owner)")
        let restored = try await late(prompt: 9) {
            try await Self.ownerRequest(bridge, prompt: 9, maxTokens: 4,
                wait: OwnerMemoryWait(limit: .seconds(30), waitsForFirstToken: false))
        }
        #expect(restored.errors.contains(InferenceTerminalCause.prefillStall.rawValue), "\(restored)")
        let darkbloom = try await late(prompt: 10) {
            try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 10),
                request: .init(model: Self.model, messages: [], max_tokens: 4), firstContentDeadline: nil)
        }
        #expect(darkbloom.errors.contains(InferenceTerminalCause.prefillStall.rawValue), "\(darkbloom)")
        await bridge.shutdown()
    }

    /// With the pair's first-token allowance restored (`DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0`), it starts when the
    /// memory wait ends, as after the pair's lane queue: a request that waited longer than the allowance still starts.
    @Test func thePairsFirstTokenAllowanceStartsAfterTheWait() async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair,
            firstToken: try DistributedFirstTokenBudgetPolicy(baseMilliseconds: 1_500, millisecondsPerInputToken: 0))
        let received = ContinuousClock.now
        let owner = Task {
            try await Self.ownerRequest(bridge, prompt: 8, maxTokens: 4,
                wait: OwnerMemoryWait(limit: .seconds(30), retryInterval: .milliseconds(50), waitsForFirstToken: false),
                origin: received)
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
        #expect(ContinuousClock.now - start < .seconds(5))
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
        #expect(ContinuousClock.now - start < .seconds(5))
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

    /// A native block slot's shared budget is weighed against the engine's own estimate of the request (the bytes it
    /// refused), not the per-token price: a request the budget can never hold is refused at once, though its tokens
    /// alone would fit.
    @Test func aNativeBlockSlotsSharedBudgetWeighsTheBytesItRefused() async throws {
        let tokenizer = FixedLengthTokenizer()
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 1 << 30, shutdownGraceSeconds: 0,
            loopConfig: .init(stepTimeout: 60, watchdogInterval: 0.01),
            reservationForRequest: { _ in 100 << 20 },
            makeSession: { _, cancellation in HeldNativeSession(latch: WaitLatch(), cancellation: cancellation) })
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            .init(total: (2 << 30) + (64 << 20), active: 0, cache: 0, systemAvailable: .max)
        })
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 2, maxConcurrentRequests: 8, kvBytesPerToken: 1, kvBudget: budget)
        let start = ContinuousClock.now
        do {
            _ = try await Self.ownerRequest(bridge, prompt: 1, maxTokens: 2,
                wait: OwnerMemoryWait(limit: .seconds(3), retryInterval: .milliseconds(20)))
            Issue.record("served past the whole budget")
        } catch {
            #expect(Self.refusal(of: error) == OwnerMemoryWait.exceedsIdleRefusal, "\(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(engine.capacity().activeRequests + engine.capacity().waitingRequests == 0)
        await bridge.shutdown()
    }

    // MARK: - The local API

    /// This Mac's API over the pair's bridge: the status, `Retry-After` and the error message of a chat request whose
    /// prompt renders to `prompt` tokens, and how long it took.
    static func answer(_ bridge: EngineV2Bridge, prompt: Int, maxTokens: Int, stream: Bool, limit: Duration?,
                       headers extra: [String: String] = [:])
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
        var fields: HTTPFields = [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"]
        for (name, value) in extra { fields[HTTPField.Name(name)!] = value }
        let headers = fields
        let (status, retryAfter, text) = try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: headers, body: ByteBuffer(string: body))
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

    /// With no bound from the owner, the request's own `X-Darkbloom-Max-Wait` bounds its wait: `0` is the busy 503 at
    /// once, `1` the busy 503 after a second; without it the request waits for the memory and is served.
    @Test(arguments: [false, true])
    func aRequestsOwnHeaderBoundsItsWait(stream: Bool) async throws {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 0)
        let bridge = try Self.bridge(pair)
        let header = OwnerMemoryWait.requestLimitHeaderName
        let atOnce = try await Self.answer(bridge, prompt: 8, maxTokens: 4, stream: stream, limit: nil,
                                           headers: [header: "0"])
        #expect(atOnce.status == 503 && atOnce.message == memoryBusyWords, "\(atOnce.body.prefix(300))")
        #expect(atOnce.took < .milliseconds(900), "\(atOnce.took)")
        let second = try await Self.answer(bridge, prompt: 8, maxTokens: 4, stream: stream, limit: nil,
                                           headers: [header: "1"])
        #expect(second.status == 503 && second.message == memoryBusyWords && second.retryAfter == "10")
        #expect(second.took >= .seconds(1) && second.took < .seconds(5), "\(second.took)")
        let opener = Task {
            try await Task.sleep(for: .milliseconds(1_500))
            pair.setRoom(64)
        }
        let served = try await Self.answer(bridge, prompt: 8, maxTokens: 4, stream: stream, limit: nil)
        _ = try await opener.value
        #expect(served.status == 200, "\(served.body.prefix(300))")
        #expect(served.took >= .milliseconds(1_500))
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
