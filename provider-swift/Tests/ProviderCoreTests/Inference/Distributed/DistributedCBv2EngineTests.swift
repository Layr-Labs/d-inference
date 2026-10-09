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

    @Test func unsupportedRequestsNeverReserve() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        var requests: [CBv2Request] = []
        var request = distributedTestRequest(); request.sampling.temperature = 1; requests.append(request)
        request = distributedTestRequest(); request.sampling.temperature = .nan; requests.append(request)
        request = distributedTestRequest(); request.sampling.topLogprobs = 1; requests.append(request)
        request = distributedTestRequest(); request.sampling.logitBias = [1: 1]; requests.append(request)
        request = distributedTestRequest(); request.sampling.seed = 1; requests.append(request)
        request = distributedTestRequest(); request.priority = 1; requests.append(request)
        request = distributedTestRequest(); request.promptTokens = []; requests.append(request)
        request = distributedTestRequest(); request.promptTokens = [100]; requests.append(request)
        request = distributedTestRequest(); request.promptTokens = Array(repeating: 1, count: 8193); requests.append(request)
        request = distributedTestRequest(); request.maxTokens = 129; requests.append(request)
        request = distributedTestRequest(); request.maxTokens = Int.max; requests.append(request)
        request = distributedTestRequest(); request.stopStrings = [""]; requests.append(request)
        request = distributedTestRequest(); request.prefixCacheReceiptID = .init(2); requests.append(request)
        for invalid in requests {
            #expect(throws: DistributedEngineError.self) { try engine.submit(invalid) }
        }
        #expect(owner.reserveCount == 0)
        await engine.shutdown()
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
