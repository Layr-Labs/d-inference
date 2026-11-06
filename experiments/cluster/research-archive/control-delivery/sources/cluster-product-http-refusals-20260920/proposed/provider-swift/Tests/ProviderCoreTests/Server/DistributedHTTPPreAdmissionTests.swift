import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Model-free real bridge/response ownership. Only the final test opens a
/// loopback listener; every execution owner and resource snapshot is fabricated.
@Suite(.timeLimit(.minutes(1))) struct DistributedHTTPPreAdmissionTests {
    @Test func duplicateHTTPIDRefusesWithoutRetiringOriginalRequest() async throws {
        let owner = DistributedTestOwner(), bridge = try makeBridge(owner)
        let first = try await bridge.submitTokenized(promptTokens: [1, 2], request: request(owner),
            requestId: "same", firstContentDeadline: nil)
        let refusal = await scopedRefusal(bridge, owner: owner, id: "same")
        #expect(refusal == .requestRejected("token_budget_exhausted: duplicate request ID"))
        #expect(owner.reserveCount == 1 && owner.last.releaseCount == 0 && owner.last.cancelCount == 0)
        owner.last.send(.token(4)); owner.last.send(.token(5)); owner.last.acknowledge()
        for await _ in first {}
        let released = try await httpDeliveryEventually { owner.last.releaseCount == 1 }
        #expect(released)
        await bridge.shutdown()
    }

    @Test func HTTPTokenOverflowThrowsBeforeAnyReservation() async throws {
        let owner = DistributedTestOwner(), bridge = try makeBridge(owner)
        let refusal = await scopedRefusal(bridge, owner: owner, maxTokens: .max)
        #expect(refusal == .tokenBudgetExhausted("token_budget_exhausted: request token count overflow"))
        #expect(owner.reserveCount == 0)
        let pending = await bridge.pendingSubmissionIDs, ids = await bridge.idMap
        #expect(pending.isEmpty && ids.isEmpty)
        if owner.reserveCount > 0 { owner.last.acknowledge() }
        await bridge.shutdown()
    }

    @Test func HTTPShutdownRefusesAfterEngineReferenceIsGone() async throws {
        let owner = DistributedTestOwner(), bridge = try makeBridge(owner)
        await bridge.shutdown()
        let absent = await bridge.ownedEngine == nil
        #expect(absent)
        let refusal = await scopedRefusal(bridge, owner: owner)
        #expect(refusal == .queueFull("request queue full: engine is shutting down"))
        #expect(owner.reserveCount == 0)
        let pending = await bridge.pendingSubmissionIDs, ids = await bridge.idMap
        #expect(pending.isEmpty && ids.isEmpty)
    }

    @Test func HTTPSharedKVRefusalKeepsBudgetAndOwnerUnreserved() async throws {
        let owner = DistributedTestOwner()
        let tokenizer = TokenizerHandle(DistributedTestTokenizer())
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), detokenizers: CBv2TextDetokenizerFactory(tokenizer: tokenizer.inner))
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: {
            .init(total: 8 << 30, active: 8 << 30, cache: 0, systemAvailable: 0)
        })
        // This custom construction intentionally reaches a branch the product
        // factory excludes; it does not assign parent memory authority remotely.
        let bridge = EngineV2Bridge(engine: engine, modelId: owner.identity.modelID, tokenizer: tokenizer,
            eosTokenIds: [], kvBytesPerToken: 4_000, kvBudget: budget)
        let refusal = await scopedRefusal(bridge, owner: owner)
        #expect(refusal == .tokenBudgetExhausted("token_budget_exhausted: request requires 4 tokens but the shared KV budget has no headroom"))
        #expect(owner.reserveCount == 0)
        let reserved = await budget.outstandingReservedBytes()
        let pending = await bridge.pendingSubmissionIDs, ids = await bridge.idMap
        #expect(reserved == 0 && pending.isEmpty && ids.isEmpty)
        if owner.reserveCount > 0 { owner.last.acknowledge() }
        await bridge.shutdown()
    }

    @Test func productFactoryDoesNotAttachParentKVAuthorityOrCaches() async throws {
        let owner = DistributedTestOwner(), bridge = try makeBridge(owner)
        let budgetAbsent = await bridge.kvBudget == nil
        let rate = await bridge.kvBytesPerToken, fixed = await bridge.fixedRequestBytes
        #expect(budgetAbsent && rate == 0 && fixed == 0)
        #expect(bridge.ssdPrefixCache == nil && bridge.ssdHybridCheckpointStore == nil)
        await bridge.shutdown()
    }

    @Test func unscopedLocalEarlyRefusalsKeepLegacyErrorStreams() async throws {
        let owner = DistributedTestOwner(), bridge = try makeBridge(owner)
        let overflow = await bridge.submitTokenized(promptTokens: [1, 2], request: request(owner, maxTokens: .max))
        var overflowMessages = [String]()
        for await event in overflow { if case .error(let message) = event { overflowMessages.append(message) } }
        #expect(overflowMessages == ["token_budget_exhausted: request token count overflow"])
        await bridge.shutdown()
        let stopped = await bridge.submitTokenized(promptTokens: [1, 2], request: request(owner))
        var stoppedMessages = [String]()
        for await event in stopped { if case .error(let message) = event { stoppedMessages.append(message) } }
        #expect(stoppedMessages == ["request queue full: engine is shutting down"] && owner.reserveCount == 0)
    }

    @Test func HTTPOverflowReturnsJSONBeforeHeadersAndReleasesResponseHold() async throws {
        let session = LocalHostTestSession(), host = localHost(session)
        do {
            try await host.start()
            let port = try #require(await host.status.boundPort)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"; request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": session.model.publicModelID,
                "messages": [["role": "user", "content": "fixture"]], "temperature": 0, "stream": true, "max_tokens": Int.max])
            let (bytes, response) = try await URLSession.shared.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            let body = String(decoding: bytes, as: UTF8.self)
            #expect(http.statusCode == 503 && body.contains("error") && !body.contains("data:"))
            #expect(session.base.reserveCount == 0)
            let responses = await host.responses
            #expect(!responses.hasActiveResponse)
            if session.base.reserveCount > 0 { session.base.last.acknowledge() }
            let status = await host.stop(until: localHostDeadline())
            #expect(status.cleanupComplete)
        } catch {
            if session.base.reserveCount > 0 { session.base.last.acknowledge() }
            _ = await host.stop(until: localHostDeadline())
            throw error
        }
    }

    private func makeBridge(_ owner: DistributedTestOwner) throws -> EngineV2Bridge {
        try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
    }
    private func request(_ owner: DistributedTestOwner, maxTokens: Int = 2) -> ChatCompletionRequest {
        .init(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: maxTokens)
    }
    private func scopedRefusal(_ bridge: EngineV2Bridge, owner: DistributedTestOwner,
                               id: String = "refused", maxTokens: Int = 2) async -> MultiModelBatchSchedulerEngineError? {
        let response = DistributedHTTPResponse()
        defer { response.disconnect(); response.finish() }
        var refusal: MultiModelBatchSchedulerEngineError?
        do {
            _ = try await DistributedHTTPResponseScope.$current.withValue(response) {
                try await bridge.submitTokenized(promptTokens: [1, 2], request: request(owner, maxTokens: maxTokens),
                    requestId: id, firstContentDeadline: nil)
            }
            Issue.record("pre-admission refusal returned a stream")
        } catch { refusal = error as? MultiModelBatchSchedulerEngineError }
        #expect(response.terminal == nil && response.selectedDeadline == nil && !response.isComplete)
        return refusal
    }
}
