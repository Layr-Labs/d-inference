import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The coordinator's demand hint (a repeated prefix or first sight) has two
/// consumers: the store's write gate (by receipt) and the engine's checkpoint
/// retention (on the request). These tests pin the second path end to end
/// through the bridge.
@Suite("EngineV2Bridge checkpoint retention hint")
struct EngineV2BridgeCheckpointTargetTests {
    private final class RecordingEngine: CBv2Engine, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [CBv2Request] = []
        var submitted: [CBv2Request] { lock.withLock { requests } }

        func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
            lock.withLock { requests.append(request) }
            return AsyncStream { continuation in
                continuation.yield(.delta(text: "OK", tokens: [9], logprobs: nil))
                continuation.yield(.finished(reason: .stop, usage: .init(
                    promptTokens: request.promptTokens.count, completionTokens: 1)))
                continuation.finish()
            }
        }
        func cancel(_ id: CBv2RequestID) {}
        func capacity() -> CBv2CapacitySnapshot {
            .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                  kvBytesCapacity: 0, activeTokens: 0)
        }
        func shutdown() async {}
    }

    private struct FixedTokenizer: MLXLMCommon.Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "OK" }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
    }

    private func submit(
        demand: SSDCheckpointDonationDemand?, scope: String
    ) async throws -> CBv2Request {
        let engine = RecordingEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "hint", tokenizer: TokenizerHandle(FixedTokenizer()),
                                    eosTokenIds: [])
        let request = ChatCompletionRequest(model: "hint",
            messages: [ChatMessage(role: "user", content: "pre-tokenized")], temperature: 0, max_tokens: 1)
        let stream = await bridge.submitTokenized(promptTokens: Array(1 ... 40), request: request,
            requestId: "hint-request", cacheScope: scope, donationDemand: demand)
        for await _ in stream {}
        await bridge.shutdown()
        return try #require(engine.submitted.first)
    }

    @Test("the coordinator hint reaches the engine request",
          arguments: [2_304, 0, 7_936])
    func hintReachesRequest(tokens: Int) async throws {
        let context = RemotePrefixCacheContext(
            cacheScope: "tenant-a", cacheReceiptNonce: "nonce", repeatedPrefixTokens: tokens)
        let request = try await submit(demand: context.donationDemand, scope: try #require(context.scope))
        #expect(request.prefixCheckpointTargetTokens == tokens)
        #expect(request.prefixCacheEnabled)
    }

    @Test("the larger of the repeat and first-sight counts reaches the engine as the checkpoint target")
    func firstSightReachesRequest() async throws {
        for (repeated, firstSight, target) in [
            (0, 2_048, 2_048), (4_096, 0, 4_096), (1_024, 3_072, 3_072), (3_072, 1_024, 3_072),
        ] {
            let context = RemotePrefixCacheContext(
                cacheScope: "tenant-a", cacheReceiptNonce: "nonce", repeatedPrefixTokens: repeated,
                firstSightTokens: firstSight)
            #expect(context.donationDemand == SSDCheckpointDonationDemand(
                repeatedPrefixTokens: repeated, firstSightTokens: firstSight))
            let request = try await submit(demand: context.donationDemand, scope: try #require(context.scope))
            #expect(request.prefixCheckpointTargetTokens == target)
        }
    }

    @Test("a frame without first sight hands the store and the engine exactly the repeat count")
    func absentFirstSight() async throws {
        let context = RemotePrefixCacheContext(
            cacheScope: "tenant-a", cacheReceiptNonce: "nonce", repeatedPrefixTokens: 2_304)
        #expect(context.firstSightTokens == 0)
        #expect(context.donationDemand == SSDCheckpointDonationDemand(repeatedPrefixTokens: 2_304))
        let request = try await submit(demand: context.donationDemand, scope: "tenant-a")
        #expect(request.prefixCheckpointTargetTokens == 2_304)
        #expect(RemotePrefixCacheContext(
            cacheScope: "tenant-a", cacheReceiptNonce: "nonce", repeatedPrefixTokens: 0,
            firstSightTokens: -5).firstSightTokens == 0)
    }

    @Test("no hint, or a request outside any cache scope, carries no retention target")
    func absentHint() async throws {
        let older = RemotePrefixCacheContext(cacheScope: "tenant-a", cacheReceiptNonce: "nonce")
        #expect(older.donationDemand == nil)
        let unhinted = try await submit(demand: older.donationDemand, scope: "tenant-a")
        #expect(unhinted.prefixCheckpointTargetTokens == nil)

        let unscoped = RemotePrefixCacheContext(
            cacheScope: nil, cacheReceiptNonce: "nonce", repeatedPrefixTokens: 4_096)
        #expect(unscoped.donationDemand == nil, "a hint without an authenticated scope is not demand")
        let disabled = EngineV2Translation.cbv2Request(
            id: .init(1), promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(model: "hint",
                messages: [ChatMessage(role: "user", content: "x")], temperature: 0, max_tokens: 1),
            defaultMaxTokens: 1, stopTokenIds: [], cacheScope: "", cacheEnabled: false,
            prefixCheckpointTargetTokens: 4_096)
        #expect(disabled.prefixCheckpointTargetTokens == nil)
        #expect(!disabled.prefixCacheEnabled)
    }
}
