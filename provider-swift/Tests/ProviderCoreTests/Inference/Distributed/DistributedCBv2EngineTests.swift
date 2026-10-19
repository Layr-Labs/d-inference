import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Fabricated owners only: no model, GPU, peer process, memory admission or
/// physical/numerical qualification is established by this suite.
@Suite(.timeLimit(.minutes(1)))
struct DistributedCBv2EngineTests {
    @Test func requiresBothLoadedPeersAndExactIdentity() throws {
        let owner = DistributedTestOwner()
        owner.available = false
        #expect(throws: DistributedEngineError.self) { try distributedTestEngine(owner) }
        owner.available = true
        let wrong = DistributedResidentIdentity(
            membershipEpoch: UUID(), modelID: owner.identity.modelID,
            artifactSHA256: owner.identity.artifactSHA256,
            configurationSHA256: owner.identity.configurationSHA256, peers: owner.identity.peers)
        #expect(throws: DistributedEngineError.self) {
            try DistributedCBv2Engine(
                owner: owner, expectedIdentity: wrong, profile: distributedTestProfile(),
                detokenizers: DistributedTestDetokenizers())
        }
        #expect(owner.reserveCount == 0)
    }

    @Test func successfulStreamHoldsSlotAndResourcesThroughRetirement() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest())
        let lease = owner.last
        #expect(lease.send(.token(4)))
        #expect(!lease.send(.token(5)))
        #expect(lease.cancelCount == 0) // length requires clean finish, not failed cancel
        #expect(lease.releaseCount == 0)
        #expect(engine.capacity().activeRequests == 1)
        #expect(engine.capacity().kvBytesReserved == 64)
        #expect(throws: CBv2KVError.self) { try engine.submit(distributedTestRequest(2)) }
        lease.acknowledge()
        let events = await distributedCollect(stream)
        #expect(distributedText(events) == "t4t5")
        #expect(distributedTerminal(events)?.0 == .length)
        #expect(distributedTerminal(events)?.1.completionTokens == 2)
        #expect(distributedTerminal(events)?.1.prefixCacheHitTokens == 0)
        #expect(lease.releaseCount == 1)
        #expect(engine.capacity().activeRequests == 0)
        #expect(engine.capacity().kvBytesReserved == 0)
        await engine.shutdown()
    }

    /// Batch lanes: an owner that serves two requests at once gets two
    /// concurrent streams, each with its own tokens and terminal; a third is
    /// refused until one retires, and the slot is reusable after release.
    @Test func batchLanesServeConcurrentRequestsIndependently() async throws {
        let owner = DistributedTestOwner()
        owner.lanes = 2
        let engine = try distributedTestEngine(owner)
        let first = try engine.submit(distributedTestRequest(1))
        let second = try engine.submit(distributedTestRequest(2))
        #expect(owner.reserveCount == 2)
        #expect(engine.capacity().activeRequests == 2)
        #expect(engine.capacity().kvBytesReserved == 128)
        #expect(throws: CBv2KVError.self) { try engine.submit(distributedTestRequest(3)) }
        let a = owner.lease(0), b = owner.lease(1)
        #expect(a.send(.token(4)))
        #expect(b.send(.token(7)))
        #expect(!b.send(.token(8)))
        #expect(!a.send(.token(5)))
        b.acknowledge()
        let secondEvents = await distributedCollect(second)
        #expect(distributedText(secondEvents) == "t7t8")
        #expect(distributedTerminal(secondEvents)?.0 == .length)
        #expect(engine.capacity().activeRequests == 1)
        // The freed lane takes another request while the first still runs.
        let third = try engine.submit(distributedTestRequest(3))
        let c = owner.lease(2)
        a.acknowledge()
        let firstEvents = await distributedCollect(first)
        #expect(distributedText(firstEvents) == "t4t5")
        #expect(c.send(.token(9)))
        #expect(!c.send(.token(10)))
        c.acknowledge()
        let thirdEvents = await distributedCollect(third)
        #expect(distributedText(thirdEvents) == "t9t10")
        #expect([a, b, c].allSatisfy { $0.releaseCount == 1 && $0.cancelCount == 0 })
        #expect(engine.capacity().activeRequests == 0)
        await engine.shutdown()
        #expect(owner.shutdownCount == 1)
    }

    /// The peers' prefix report: a receipt is accepted, the reuse is the
    /// usage's hit, and the frontiers both peers hold reach the publication
    /// handler with the receipt. A report never changes the token stream.
    @Test func peerPrefixReuseIsReportedInUsageAndPublished() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let published = DistributedPublishedFrontiers()
        engine.setResidentPrefixPublicationHandler { receipt, frontiers in published.record(receipt, frontiers) }
        var request = distributedTestRequest(); request.promptTokens = [1, 2, 3, 1, 2]
        request.prefixCacheReceiptID = .init(77)
        let stream = try engine.submit(request)
        let lease = owner.last
        #expect(lease.send(.token(4)))
        #expect(!lease.send(.token(5)))
        // After the last token, before the finish: the report still counts.
        lease.send(.promptCache(reused: 4, stored: [2, 4]))
        lease.acknowledge()
        let events = await distributedCollect(stream)
        #expect(distributedText(events) == "t4t5")
        let usage = distributedTerminal(events)?.1
        #expect(usage?.prefixCacheHitTokens == 4 && usage?.prefixCachePrefillTokensSaved == 4)
        #expect(usage?.prefixCacheOutcome == .hit && usage?.prefixCacheTier == .resident)
        #expect(published.values == [(77, [2, 4])].map { "\($0.0):\($0.1)" })
        await engine.shutdown()
    }

    @Test func aColdRequestReportsNoHitAndPublishesNothingWithoutFrontiers() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let published = DistributedPublishedFrontiers()
        engine.setResidentPrefixPublicationHandler { receipt, frontiers in published.record(receipt, frontiers) }
        var request = distributedTestRequest(); request.prefixCacheReceiptID = .init(78)
        let stream = try engine.submit(request)
        owner.last.send(.token(4)); owner.last.send(.token(5))
        owner.last.acknowledge()
        let usage = distributedTerminal(await distributedCollect(stream))?.1
        #expect(usage?.prefixCacheHitTokens == 0 && usage?.prefixCacheOutcome != .hit)
        #expect(published.values.isEmpty)
        await engine.shutdown()
    }

    @Test func stopTokenAndSplitStopStringDoNotLeakText() async throws {
        for stopToken in [true, false] {
            let owner = DistributedTestOwner()
            let engine = try distributedTestEngine(owner)
            var request = distributedTestRequest(maxTokens: 3)
            if stopToken { request.stopTokens = [4] }
            else { request.stopStrings = ["t4t5"] }
            let stream = try engine.submit(request)
            owner.last.send(.token(4))
            if !stopToken { owner.last.send(.token(5)) }
            #expect(owner.last.cancelCount == 0) // EOS and stop strings clean-finish too
            owner.last.acknowledge()
            let events = await distributedCollect(stream)
            #expect(distributedText(events).isEmpty)
            #expect(distributedTerminal(events)?.0 == .stop)
            #expect(distributedTerminal(events)?.1.completionTokens == (stopToken ? 1 : 2))
            await engine.shutdown()
        }
    }

    @Test func cancellationSuppressesLateTokensButDoesNotInventRetirement() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest())
        engine.cancel(.init(999))
        #expect(owner.last.cancelCount == 0)
        engine.cancel(.init(1))
        engine.cancel(.init(1))
        #expect(owner.last.cancelCount == 1)
        #expect(!owner.last.send(.token(4)))
        #expect(owner.last.releaseCount == 0)
        #expect(engine.capacity().activeRequests == 1)
        owner.last.acknowledge()
        let events = await distributedCollect(stream)
        #expect(distributedTerminal(events)?.0 == .cancelled)
        #expect(distributedTerminal(events)?.1.completionTokens == 0)
        await engine.shutdown()
    }

    @Test func peerLossWithdrawsCapacityAndOverridesPendingSuccess() async throws {
        for notify in [true, false] {
            let owner = DistributedTestOwner()
            let engine = try distributedTestEngine(owner)
            let stream = try engine.submit(distributedTestRequest(maxTokens: 1))
            owner.last.send(.token(4))
            owner.losePeer(notify: notify)
            #expect(engine.capacity().kvBytesCapacity == 0)
            #expect(engine.capacity().activeRequests == 1)
            owner.last.acknowledge()
            let events = await distributedCollect(stream)
            #expect(distributedTerminal(events)?.0 == .error("distributed peer readiness lost"))
            owner.available = true // a lost membership cannot silently revive this engine
            #expect(engine.capacity().kvBytesCapacity == 0)
            #expect(throws: DistributedEngineError.self) { try engine.submit(distributedTestRequest(2)) }
            await engine.shutdown()
        }
    }

    /// Every refusal names its rule (a 4xx with that reason at the client)
    /// and never reaches the owner.
    @Test func unsupportedRequestsAreRefusedWithTheirReasonAndNeverReserve() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        var cases: [(CBv2Request, DistributedRequestRefusal)] = []
        var request = distributedTestRequest(); request.sampling.temperature = .nan; cases.append((request, .invalidSampling))
        request = distributedTestRequest(); request.sampling.logitBias = [1: .infinity]; cases.append((request, .invalidSampling))
        request = distributedTestRequest(); request.sampling.topLogprobs = 1; cases.append((request, .logprobsUnsupported))
        request = distributedTestRequest(); request.priority = 1; cases.append((request, .priorityUnsupported))
        request = distributedTestRequest(); request.promptTokens = []; cases.append((request, .emptyPrompt))
        request = distributedTestRequest(); request.promptTokens = [100]; cases.append((request, .tokenOutsideVocabulary))
        request = distributedTestRequest(); request.stopTokens = [100]; cases.append((request, .tokenOutsideVocabulary))
        request = distributedTestRequest(); request.promptTokens = Array(repeating: 1, count: 8193); cases.append((request, .promptTooLong))
        request = distributedTestRequest(); request.maxTokens = 0; cases.append((request, .invalidMaxTokens))
        request = distributedTestRequest(); request.maxTokens = 129; cases.append((request, .outputTooLong))
        request = distributedTestRequest(); request.maxTokens = Int.max; cases.append((request, .outputTooLong))
        request = distributedTestRequest(); request.stopStrings = [""]; cases.append((request, .invalidStopSequences))
        for (invalid, reason) in cases {
            #expect(throws: DistributedEngineError.refused(reason)) { try engine.submit(invalid) }
        }
        #expect(owner.reserveCount == 0)
        await engine.shutdown()
    }

    /// Sampling is served: the owner receives the request's values, with an
    /// omitted seed resolved to the engine's own fallback (as the product's
    /// engine keys unseeded rows), and a seeded request keeps its seed.
    @Test func sampledRequestsReachTheOwnerWithAResolvedSeed() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        for seed in [nil, UInt64(42)] {
            var request = distributedTestRequest(UInt64(seed ?? 7), maxTokens: 1)
            request.sampling = .init(temperature: 0.7, topP: 0.9, topK: 20, repetitionPenalty: 1.1,
                presencePenalty: 0.5, seed: seed, logitBias: [5: -100, 1000: 3])
            let stream = try engine.submit(request)
            owner.last.send(.token(4)); owner.last.acknowledge()
            _ = await distributedCollect(stream)
            let reserved = try #require(owner.reservedRequests.last)
            #expect(reserved.sampling.seed == (seed ?? engine.fallbackSeed))
            let wire = try #require(DistributedSampling.wire(for: reserved, vocabularySize: 100))
            #expect(wire.temperature == 0.7 && wire.topP == 0.9 && wire.topK == 20 && wire.stream == reserved.id.raw)
            #expect(wire.seed == (seed ?? engine.fallbackSeed) && wire.repetitionPenalty == 1.1 && wire.presencePenalty == 0.5)
            // Bias for a token outside the vocabulary has no effect and is dropped.
            #expect(wire.logitBias == [.init(tokenID: 5, bias: -100)])
        }
        // Greedy text with no transform carries no sampling at all.
        #expect(DistributedSampling.wire(for: distributedTestRequest(), vocabularySize: 100) == nil)
        var greedyBias = distributedTestRequest(); greedyBias.sampling.logitBias = [3: 5]
        #expect(DistributedSampling.wire(for: greedyBias, vocabularySize: 100)?.isStochastic == false)
        var wideTopK = distributedTestRequest(); wideTopK.sampling.temperature = 1; wideTopK.sampling.topK = 500
        #expect(DistributedSampling.wire(for: wideTopK, vocabularySize: 100)?.topK == 0)
        await engine.shutdown()
    }

    @Test func refusalsBecomeClientErrorsWithTheirReason() throws {
        let profile = try distributedTestProfile()
        for refusal in DistributedRequestRefusal.allCases {
            let message = EngineV2Translation.admissionErrorMessage(
                for: DistributedEngineError.refused(refusal), distributedProfile: profile)
            let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            guard case .distributedRequestRefused(let parsed, let text) = typed else {
                Issue.record("\(refusal) did not parse: \(message)"); continue
            }
            #expect(parsed == refusal && text == refusal.message(profile))
            #expect(ProviderLoop.mapInferenceErrorToStatus(typed) == 400)
            let failure = ProviderLoop.sanitizedInferenceFailure(from: typed, phase: .generation)
            // Over this pair's context: the coordinator may route it to a node
            // with more room (the product's own `request_exceeds_context`
            // classification); every other refusal is the client's.
            #expect(failure.code == (refusal.exceedsContext ? .capacity : .invalidRequest))
            #expect(failure.errorReason == (refusal.exceedsContext ? .requestExceedsContext : .clientError))
        }
        #expect(DistributedRequestRefusal.outputTooLong.message(profile).contains("128"))
        let unavailable = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
            EngineV2Translation.admissionErrorMessage(for: DistributedEngineError.unavailable))
        #expect(ProviderLoop.mapInferenceErrorToStatus(unavailable) == 503)
        let busy = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
            EngineV2Translation.admissionErrorMessage(for: CBv2KVError.capacityExhausted(needed: 1, available: 0)))
        #expect(ProviderLoop.mapInferenceErrorToStatus(busy) == 429)
        // An omitted max_tokens receives the cluster's full allowance, cut to remaining context.
        #expect(DistributedEngineFactory.defaultOutputTokens == 32_768)
        #expect(EngineV2Translation.defaultOutputTokens(DistributedEngineFactory.defaultOutputTokens,
            promptTokens: 100, contextLimit: 65_536) == 32_768)
        #expect(EngineV2Translation.defaultOutputTokens(DistributedEngineFactory.defaultOutputTokens,
            promptTokens: 100, contextLimit: 4096) == 3996)
        // Existing explicit defaults continue to clamp identically.
        #expect(EngineV2Translation.defaultOutputTokens(4096, promptTokens: 30_000, contextLimit: 32_768) == 2768)
        #expect(EngineV2Translation.defaultOutputTokens(4096, promptTokens: 100, contextLimit: 32_768) == 4096)
        #expect(EngineV2Translation.defaultOutputTokens(4096, promptTokens: 40_000, contextLimit: 32_768) == 1)
        #expect(EngineV2Translation.defaultOutputTokens(4096, promptTokens: 30_000, contextLimit: nil) == 4096)
    }

    @Test func customProfileAndBudgetAreEnforcedWithoutGeometryAssumptions() async throws {
        let owner = DistributedTestOwner()
        let engine = try DistributedCBv2Engine(
            owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(maxPrompt: 2, maxOutput: 1),
            detokenizers: DistributedTestDetokenizers())
        #expect(throws: DistributedEngineError.self) { try engine.submit(distributedTestRequest()) }
        engine.updateKVBytesCapacity(32)
        #expect(engine.capacity().kvBytesCapacity == 32)
        var request = distributedTestRequest(maxTokens: 1); request.promptTokens = [1]
        #expect(throws: DistributedEngineError.self) { try engine.submit(request) }
        #expect(owner.reserveCount == 0)
        engine.updateKVBytesCapacity(Int.max)
        #expect(engine.capacity().kvBytesCapacity == 1024)
        await engine.shutdown()
    }

    @Test func invalidOwnerReservationAndStartFailureBothRetireBeforeRelease() async throws {
        for badIdentity in [true, false] {
            let owner = DistributedTestOwner()
            owner.badReservationIdentity = badIdentity
            owner.throwOnStart = !badIdentity
            let engine = try distributedTestEngine(owner)
            let stream = try engine.submit(distributedTestRequest())
            #expect(owner.last.startCount == (badIdentity ? 0 : 1))
            #expect(owner.last.cancelCount == 1)
            #expect(owner.last.releaseCount == 0)
            owner.last.acknowledge()
            let events = await distributedCollect(stream)
            guard let terminal = distributedTerminal(events), case .error = terminal.0 else {
                Issue.record("expected retained owner failure"); return
            }
            #expect(owner.last.releaseCount == 1)
            await engine.shutdown()
        }
    }

    @Test func malformedTokenOrEarlyLengthIsAStreamFailure() async throws {
        let invalidEvents: [DistributedResidentEvent] = [.token(100), .finished(.length), .finished(.stop)]
        for event in invalidEvents {
            let owner = DistributedTestOwner()
            let engine = try distributedTestEngine(owner)
            let stream = try engine.submit(distributedTestRequest())
            #expect(!owner.last.send(event))
            #expect(owner.last.cancelCount == 1)
            owner.last.acknowledge()
            let events = await distributedCollect(stream)
            guard let terminal = distributedTerminal(events), case .error = terminal.0 else {
                Issue.record("expected invalid owner output failure"); return
            }
            #expect(distributedTerminal(events)?.1.completionTokens == 0)
            await engine.shutdown()
        }
    }

    @Test func shutdownWaitsForRetirementAndClosesOwnerOnce() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest())
        let shutdown = engine.onQueue { engine.beginShutdown() }
        #expect(owner.last.cancelCount == 1)
        #expect(owner.shutdownCount == 0)
        #expect(owner.last.releaseCount == 0)
        #expect(throws: DistributedEngineError.self) { try engine.submit(distributedTestRequest(2)) }
        owner.last.acknowledge()
        async let first: Void = engine.shutdown()
        async let second: Void = engine.shutdown()
        await first; await second
        await shutdown.value
        _ = await distributedCollect(stream)
        #expect(owner.last.releaseCount == 1)
        #expect(owner.shutdownCount == 1)
        #expect(engine.capacity().kvBytesCapacity == 0)
        #expect(throws: DistributedEngineError.self) { try engine.submit(distributedTestRequest(2)) }
    }

    @Test func cancelledStreamConsumerRetainsOwnerUntilAck() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest())
        let consumer = Task { await distributedCollect(stream) }
        consumer.cancel()
        _ = await consumer.value
        #expect(owner.last.cancelCount == 1)
        #expect(owner.last.releaseCount == 0)
        #expect(engine.capacity().activeRequests == 1)
        owner.last.acknowledge()
        await engine.shutdown()
        #expect(owner.last.releaseCount == 1)
    }

    @Test func experimentalFactoryStreamsThroughExistingProviderBridge() async throws {
        let owner = DistributedTestOwner()
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 1),
            requestId: "distributed-factory-fixture", cacheEnabled: false)
        try #require(owner.reserveCount == 1)
        owner.last.send(.token(4))
        #expect(owner.last.releaseCount == 0)
        owner.last.acknowledge()
        var text = ""
        var terminals = 0
        for await event in stream {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info(let prompt, let completion, _, let reason):
                #expect(prompt == 3 && completion == 1 && reason == "length")
                terminals += 1
            case .error(let error): #expect(error.isEmpty)
            case .terminal: Issue.record("unexpected deadline terminal")
            }
        }
        #expect(text == "t4")
        #expect(terminals == 1)
        #expect(owner.last.releaseCount == 1)
        await bridge.shutdown()
        #expect(owner.shutdownCount == 1)
    }
}


final class DistributedPublishedFrontiers: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ receipt: CBv2RequestID, _ frontiers: [Int]) {
        lock.withLock { recorded.append("\(receipt.raw):\(frontiers)") }
    }
    var values: [String] { lock.withLock { recorded } }
}
