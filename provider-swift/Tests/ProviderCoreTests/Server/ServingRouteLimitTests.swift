import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Every limit that depends on whose request it is, on the fabricated engines of `LocalMemoryWaitTests`,
/// `LocalHeadHoldTests` and `DistributedHTTPOriginTests` (no process, model or GPU). Each case holds one resource
/// past the bound a Darkbloom request gets, then releases it: the owner's request on the local API is served, and
/// every other request gets the answer the coordinator re-routes on. Time is the test's: a pair's deadlines are read
/// on a clock the test advances, the engine's admission lease ends when the test ends it, and memory comes back when
/// the test releases it.
///
/// `today` is the golden table: one row per limit, one answer per route. A change to a row is a change to what a
/// client or the coordinator sees.
@Suite("Each limit, per serving route", .serialized, .timeLimit(.minutes(2)))
struct ServingRouteLimitTests {
    static let model = LocalMemoryWaitTests.model

    /// Whose request a submission is, as the bridge is told today.
    enum Route: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// A Darkbloom request: its coordinator id is bound, and it names no first-content budget.
        case coordinator
        /// The owner's request on the local API: the owner's wait is bound.
        case owner
        /// A loop exit's continuation of the owner's request: the owner's wait, and an admission priority above 0.
        case ownerContinuation
        /// Neither: a request the provider submits itself.
        case `internal`

        var testDescription: String { rawValue }
    }

    enum Limit: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The memory a running request holds, on a pair and on one Mac.
        case pairMemory, slotMemory
        /// One Mac's engine queue: the admission lease of a request it queued and never admitted.
        case slotAdmissionLease
        /// A pair's first-token allowance (10 s here), request deadline (the setup's, 30 s here) and served context
        /// (6 tokens here, 20 for the owner).
        case pairFirstToken, pairRequestDeadline, pairContext

        var testDescription: String { rawValue }
    }

    /// What each route gets today, per limit.
    static let today: [Limit: [Route: String]] = [
        .pairMemory: [
            .coordinator: "refused 503 request_exceeds_node_budget",
            .owner: "waits, then served 30 tokens",
            .ownerContinuation: "refused 400 priority_unsupported: Request priority is not supported on this cluster.",
            .internal: "refused 503 request_exceeds_node_budget",
        ],
        .slotMemory: [
            .coordinator: "refused 503 request_exceeds_node_budget",
            .owner: "waits, then served 1 tokens",
            .ownerContinuation: "refused 503 request_exceeds_node_budget",
            .internal: "refused 503 request_exceeds_node_budget",
        ],
        .slotAdmissionLease: [
            .coordinator: "ended admission_timeout",
            .owner: "waits, then served 1 tokens",
            .ownerContinuation: "ended admission_timeout",
            .internal: "ended admission_timeout",
        ],
        .pairFirstToken: [
            .coordinator: "ended prefill_stall; first token within 10 s, request within 30 s",
            .owner: "served 2 tokens; first token within no limit, request within 3600 s",
            .ownerContinuation: "refused 400 priority_unsupported: Request priority is not supported on this cluster.",
            .internal: "ended prefill_stall; first token within 10 s, request within 30 s",
        ],
        .pairRequestDeadline: [
            .coordinator: "ended safety_deadline; first token within no limit, request within 30 s",
            .owner: "served 2 tokens; first token within no limit, request within 3600 s",
            .ownerContinuation: "refused 400 priority_unsupported: Request priority is not supported on this cluster.",
            .internal: "ended safety_deadline; first token within no limit, request within 30 s",
        ],
        .pairContext: [
            .coordinator: "refused 400 context_length_exceeded: "
                + DistributedRequestRefusal.contextLengthExceededMessage(contextTokens: 6),
            .owner: "served 4 tokens; first token within no limit, request within 3600 s",
            .ownerContinuation: "refused 400 priority_unsupported: Request priority is not supported on this cluster.",
            .internal: "refused 400 context_length_exceeded: "
                + DistributedRequestRefusal.contextLengthExceededMessage(contextTokens: 6),
        ],
    ]

    @Test(arguments: Limit.allCases, Route.allCases)
    func aLimitHeldPastTheDarkbloomBoundThenReleased(limit: Limit, route: Route) async throws {
        let answer: String
        switch limit {
        case .pairMemory: answer = try await Self.pairMemory(route)
        case .slotMemory:
            answer = await Self.slotMemory { bridge in
                try await Self.submit(route, to: bridge, prompt: 8, maxTokens: 40,
                                      wait: OwnerMemoryWait(retryInterval: .milliseconds(10)))
            }
        case .slotAdmissionLease: answer = try await Self.slotAdmissionLease(route)
        case .pairFirstToken:
            answer = try await Self.pairDeadline(route, past: .seconds(11),
                firstToken: try DistributedFirstTokenBudgetPolicy(baseMilliseconds: 10_000, millisecondsPerInputToken: 0))
        case .pairRequestDeadline: answer = try await Self.pairDeadline(route, past: .seconds(31))
        case .pairContext: answer = try await Self.pairDeadline(route, prompt: 8, maxTokens: 4)
        }
        #expect(answer == Self.today[limit]?[route], "\(limit.rawValue), \(route.rawValue)")
    }

    /// A request with a coordinator's first-content budget is never the owner's, even where the owner's wait is bound:
    /// it is refused at once, so the coordinator can send it elsewhere within that budget.
    @Test func aRequestWithACoordinatorBudgetIsNeverTheOwners() async throws {
        let answer = await Self.slotMemory { bridge in
            try await OwnerMemoryWait.$current.withValue(OwnerMemoryWait()) {
                try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 8),
                    request: .init(model: Self.model, messages: [], max_tokens: 40), requestId: UUID().uuidString,
                    firstContentDeadline: FirstContentDeadline(relativeBudgetMilliseconds: 60_000))
            }
        }
        #expect(answer == "refused 503 request_exceeds_node_budget")
    }

    /// The owner's own setting gives the pair's first-token allowance back to the owner's requests
    /// (`DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0`): they then end as a Darkbloom request does, within the hour all the same.
    @Test func anOwnerWhoRestoresTheFirstTokenAllowanceIsHeldToIt() async throws {
        let answer = try await Self.pairDeadline(.owner, past: .seconds(11),
            firstToken: try DistributedFirstTokenBudgetPolicy(baseMilliseconds: 10_000, millisecondsPerInputToken: 0),
            wait: OwnerMemoryWait(waitsForFirstToken: false))
        #expect(answer == "ended prefill_stall; first token within 10 s, request within 3600 s")
    }

    /// A pair cuts `max_tokens` to what it serves the route, and its refusal names those limits: the owner's are
    /// what the pair serves its owner, every other request's what it reports to the coordinator.
    @Test(arguments: Route.allCases)
    func aPairHoldsARequestToWhatItServesItsRoute(route: Route) async throws {
        let owners = route == .owner
        // A `max_tokens` past the output limit is cut to it.
        let cut = try Self.clockedPair()
        let request = Self.start {
            try await Self.submit(route, to: cut.bridge, prompt: 3, maxTokens: 100, origin: cut.clock.now)
        }
        _ = await eventually { request.answered.value > 0 || cut.owner.base.reserveCount == 1 }
        // A pair serves no continuation: it refuses a request with a priority.
        #expect(cut.owner.base.reserveCount == (route == .ownerContinuation ? 0 : 1))
        if cut.owner.base.reserveCount == 1 {
            #expect(cut.owner.base.reservedRequests.last?.maxTokens == (owners ? 4 : 2))
            #expect(await eventually { cut.owner.base.last.startCount == 1 })
            for token in 4 ..< 8 { cut.owner.base.last.send(.token(token)) }
            cut.owner.base.last.acknowledge()
        }
        _ = await Self.settled(request)
        if cut.owner.base.reserveCount > 0 { cut.owner.base.last.acknowledge() }
        await cut.bridge.shutdown()
        // A prompt past the prompt limit is refused in words that name the limit.
        let refused = try Self.clockedPair()
        let long = await Self.answer {
            try await Self.submit(route, to: refused.bridge, prompt: owners ? 17 : 5, maxTokens: 1,
                                  origin: refused.clock.now)
        }
        let expected = route == .ownerContinuation
            ? "refused 400 priority_unsupported: Request priority is not supported on this cluster."
            : "refused 400 prompt_too_long: The prompt is longer than this model's limit of \(owners ? 16 : 4) tokens "
                + "on this cluster."
        #expect(long == expected)
        #expect(refused.owner.base.reserveCount == 0)
        await refused.bridge.shutdown()
    }

    /// A request that reaches its overall deadline: a Darkbloom request keeps the typed end the coordinator reads,
    /// and the owner's on the local API is answered busy, with `Retry-After` (`LocalDeadlineOutcome`).
    @Test func atItsOverallDeadlineADarkbloomRequestKeepsItsEndAndTheOwnersIsAnsweredBusy() async throws {
        let end = CBv2FinishReason.terminal(cause: .safetyDeadline,
                                            message: "request exceeded its absolute safety ceiling")
        let darkbloom = HeadHoldEngine()
        darkbloom.admit()
        let bridge = await Self.slotBridge(darkbloom)
        let request = Self.start { try await Self.submit(.coordinator, to: bridge, prompt: 8, maxTokens: 4) }
        #expect(await eventually { darkbloom.submitted == 1 })
        darkbloom.end(end)
        #expect(await Self.settled(request) == "ended safety_deadline")
        await bridge.shutdown()

        let owners = HeadHoldEngine()
        owners.admit()
        let local = await Self.slotBridge(owners)
        let answer = Task {
            try await LocalMemoryWaitTests.answer(local, prompt: 8, maxTokens: 4, stream: false, limit: nil)
        }
        guard await eventually({ owners.submitted == 1 }) else {
            answer.cancel()
            Issue.record("the owner's request never reached the engine")
            return
        }
        owners.end(end)
        let response = try await answer.value
        #expect(response.status == 503 && response.retryAfter == String(LocalMemoryRefusal.retryAfterSeconds))
        #expect(response.message == LocalMemoryRefusal.deadline, "\(response.body.prefix(300))")
        await local.shutdown()
    }

    /// A pair's lane queue ends a waiter at a ceiling computed from the setup's request timeout
    /// (`DistributedRequestQueue.Limits.waitCeiling`), though the owner's requests ahead of it may each run for the
    /// protocol's hour: with a full default queue on an eight-lane pair and a 300 s setup, a waiter is refused after
    /// 45 minutes, before one request ahead of it must have ended. Today's behaviour, named here so that it is a
    /// decision rather than an accident.
    @Test func aPairsLaneQueueCeilingStillCountsInTheSetupsRequestTimeout() {
        let ceiling = DistributedRequestQueue.Limits.standard.waitCeiling(requestTimeout: .seconds(300), lanes: 8)
        #expect(ceiling == .seconds(300 * 9))
        #expect(ceiling < DistributedCBv2Engine.ownerRequestTimeout)
    }

    // MARK: - The resources

    /// A running request holds 48 of the pair's 64 tokens; the request under test needs 39.
    static func pairMemory(_ route: Route) async throws -> String {
        let pair = MemoryGatedPair(servingContextTokens: 64, room: 64)
        let bridge = try LocalMemoryWaitTests.bridge(pair)
        pair.holdPrompt = 8
        let running = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 8),
            request: .init(model: model, messages: [], max_tokens: 40))
        guard await eventually({ pair.reservedPrompts == [8] }) else { return "the running request never started" }
        // Only the running request's end wakes a waiter here: its own retry is a minute away.
        let request = start {
            try await submit(route, to: bridge, prompt: 9, maxTokens: 30, wait: OwnerMemoryWait(retryInterval: .seconds(60)))
        }
        let waits = await waitsForMemory(request, on: bridge)
        pair.hold.signal()
        for await _ in running {}
        let answer = await settled(request)
        await bridge.shutdown()
        return (waits ? "waits, then " : "") + answer
    }

    /// Another reservation holds 80 MiB of one Mac's 100 MiB shared budget, a MiB a token; the request under test
    /// needs 48 MiB. Its engine admits at once, and answers once the request holds its memory.
    static func slotMemory(_ submit: @escaping @Sendable (EngineV2Bridge) async throws -> AsyncStream<GenerationEvent>)
        async -> String {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            .init(total: (2 << 30) + (100 << 20), active: 0, cache: 0, systemAvailable: .max)
        })
        let engine = HeadHoldEngine()
        engine.admit()
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: TokenizerHandle(FixedLengthTokenizer()),
            eosTokenIds: [], defaultMaxTokens: 1_000, defaultMaxTokensContextLimit: 4_096, maxConcurrentRequests: 4,
            kvBytesPerToken: 1 << 20, kvBudget: budget)
        await bridge.setQueuePollIntervalForTesting(.milliseconds(5))
        guard await budget.reserveBytes(requestID: "running", bytes: 80 << 20) else {
            return "the running reservation never fit"
        }
        let request = start { try await submit(bridge) }
        let waits = await waitsForMemory(request, on: bridge)
        await budget.release(requestID: "running")
        _ = await eventually { request.answered.value > 0 || engine.submitted == 1 }
        engine.answer()
        let answer = await settled(request)
        await bridge.shutdown()
        return (waits ? "waits, then " : "") + answer
    }

    /// The engine queues the request, its admission lease runs out, then the engine admits what it holds.
    static func slotAdmissionLease(_ route: Route) async throws -> String {
        let engine = HeadHoldEngine()
        let bridge = await slotBridge(engine)
        let request = start {
            try await submit(route, to: bridge, prompt: 8, maxTokens: 4,
                             wait: OwnerMemoryWait(retryInterval: .milliseconds(10)))
        }
        guard await eventually({ engine.submitted == 1 }) else {
            request.answer.cancel()
            return "the request never reached the engine"
        }
        engine.endLast(.terminal(cause: .admissionTimeout, message: "admission lease expired"))
        _ = await eventually { request.answered.value > 0 || engine.submitted == 2 }
        let waits = engine.submitted == 2
        engine.admit()
        engine.answer()
        let answer = await settled(request)
        await bridge.shutdown()
        return (waits ? "waits, then " : "") + answer
    }

    /// On a pair that serves the owner 20 tokens of context and every other request 6: the request is reserved, the
    /// clock passes `bound`, then the ranks give its tokens. The answer names the deadlines it was reserved with.
    static func pairDeadline(_ route: Route, past bound: Duration = .zero,
                             firstToken: DistributedFirstTokenBudgetPolicy? = nil, prompt: Int = 3, maxTokens: Int = 2,
                             wait: OwnerMemoryWait = OwnerMemoryWait()) async throws -> String {
        let pair = try clockedPair(firstToken: firstToken)
        let origin = pair.clock.now
        let request = start {
            try await submit(route, to: pair.bridge, prompt: prompt, maxTokens: maxTokens, wait: wait, origin: origin)
        }
        _ = await eventually {
            request.answered.value > 0 || (pair.owner.base.reserveCount == 1 && pair.owner.base.last.startCount == 1)
        }
        var deadlines = ""
        if pair.owner.base.reserveCount == 1, let context = pair.owner.context {
            pair.clock.advance(bound)
            let lease = pair.owner.base.last
            for token in 4 ..< 4 + maxTokens { lease.send(.token(token)) }
            lease.acknowledge()
            let first = context.firstTokenDeadline.map { "\(origin.duration(to: $0).components.seconds) s" } ?? "no limit"
            deadlines = "; first token within \(first), request within "
                + "\(origin.duration(to: context.generationDeadline).components.seconds) s"
        }
        let answer = await settled(request)
        // A reservation the test missed is retired all the same, so the pair can stop.
        if pair.owner.base.reserveCount > 0 { pair.owner.base.last.acknowledge() }
        await pair.bridge.shutdown()
        return answer + deadlines
    }

    // MARK: - Fixtures

    /// One request of `prompt` tokens and `maxTokens` straight to the bridge, as each route submits it.
    static func submit(_ route: Route, to bridge: EngineV2Bridge, prompt: Int, maxTokens: Int,
                       wait: OwnerMemoryWait = OwnerMemoryWait(),
                       origin: ContinuousClock.Instant? = nil) async throws -> AsyncStream<GenerationEvent> {
        @Sendable func send() async throws -> AsyncStream<GenerationEvent> {
            try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: model, messages: [], max_tokens: maxTokens), requestId: UUID().uuidString,
                firstContentDeadline: nil, distributedRequestOrigin: origin)
        }
        switch route {
        case .coordinator:
            return try await MeFirstDarkbloomRequest.$id.withValue("darkbloom-request") { try await send() }
        case .owner:
            return try await OwnerMemoryWait.$current.withValue(wait) { try await send() }
        case .ownerContinuation:
            return try await OwnerMemoryWait.$current.withValue(wait) {
                try await EngineAdmissionPriority.$current.withValue(1) { try await send() }
            }
        case .internal:
            return try await send()
        }
    }

    /// A request's answer: the tokens it was served, the end its stream carried, or the refusal the coordinator
    /// would be sent (its status and reason, and a pair's own words for a request it refuses by its limits).
    static func answer(_ submit: @Sendable () async throws -> AsyncStream<GenerationEvent>) async -> String {
        do {
            var tokens = 0, end: String?
            for await event in try await submit() {
                switch event {
                case .info(_, let completionTokens, _, _): tokens = completionTokens
                case .error(let message): end = end ?? "failed: \(message)"
                case .terminal(let cause, _, _, _): end = end ?? "ended \(cause.rawValue)"
                default: break
                }
            }
            return end ?? "served \(tokens) tokens"
        } catch {
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
            var refusal = "refused \(failure.statusCode) \(failure.errorReason?.rawValue ?? failure.code.rawValue)"
            if case .distributedRequestRefused(let rule, let message)? = error as? MultiModelBatchSchedulerEngineError {
                refusal = "refused \(failure.statusCode) \(rule.rawValue): \(message)"
            }
            return refusal
        }
    }

    /// `submit` in its own task: its answer, and whether it has one yet.
    static func start(_ submit: @escaping @Sendable () async throws -> AsyncStream<GenerationEvent>)
        -> (answer: Task<String, Never>, answered: WaitCounter) {
        let answered = WaitCounter()
        let task = Task { () -> String in
            let result = await answer(submit)
            answered.add()
            return result
        }
        return (task, answered)
    }

    /// The request's answer. One still unanswered 5 s after its resource was given back is cancelled, so a state
    /// the test missed fails its row instead of hanging the run.
    static func settled(_ request: (answer: Task<String, Never>, answered: WaitCounter)) async -> String {
        if !(await eventually { request.answered.value > 0 }) { request.answer.cancel() }
        return await request.answer.value
    }

    /// Whether the request waits for memory on `bridge` rather than being answered at once.
    static func waitsForMemory(_ request: (answer: Task<String, Never>, answered: WaitCounter),
                               on bridge: EngineV2Bridge) async -> Bool {
        _ = await eventually {
            if request.answered.value > 0 { return true }
            return await bridge.ownerMemoryWaiters.waiting.count == 1
        }
        return request.answered.value == 0
    }

    /// One Mac's slot over `engine`, looking every 5 ms whether a held request still waits in the engine's queue.
    static func slotBridge(_ engine: any CBv2Engine) async -> EngineV2Bridge {
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: TokenizerHandle(FixedLengthTokenizer()),
            eosTokenIds: [], defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: 262_144, maxConcurrentRequests: 4,
            kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        await bridge.setQueuePollIntervalForTesting(.milliseconds(5))
        return bridge
    }

    /// A fabricated pair whose engine reads the test's clock, with a 30 s setup request timeout. It serves 4 prompt
    /// tokens, 2 of output and 6 of context, and its owner 16, 4 and 20.
    static func clockedPair(firstToken: DistributedFirstTokenBudgetPolicy? = nil) throws
        -> (bridge: EngineV2Bridge, owner: HTTPOriginOwner, clock: DistributedTestClock) {
        let owner = HTTPOriginOwner(), clock = DistributedTestClock()
        let profile = try DistributedResidentExecutionProfile(id: "fabricated-greedy", vocabularySize: 100,
            maxPromptTokens: 16, maxOutputTokens: 4, maxContextTokens: 20, requestTimeout: .seconds(30),
            served: (promptTokens: 4, outputTokens: 2, contextTokens: 6),
            ownerServed: (promptTokens: 16, outputTokens: 4, contextTokens: 20))
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.base.identity, profile: profile,
            detokenizers: DistributedTestDetokenizers(), clock: clock.clock)
        let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: TokenizerHandle(DistributedTestTokenizer()),
            eosTokenIds: [99], distributedFirstTokenBudgetPolicy: firstToken)
        return (bridge, owner, clock)
    }
}

/// Polls `condition` every 5 ms for up to 5 s: a wait for a state, never for a time to pass.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
