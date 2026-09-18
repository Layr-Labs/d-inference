import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Test("shared local engine preserves per-request cache usage across concurrent calls")
func localEngineCacheUsageIsRequestOwned() async throws {
    let tokenizer = TokenizerHandle(CacheUsageTokenizer())
    let bridge = EngineV2Bridge(engine: CacheUsageEngine(), modelId: "cache-usage",
                               tokenizer: tokenizer, eosTokenIds: [])
    let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
        tokenizer: tokenizer, engineV2Bridge: bridge)
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { ["cache-usage": entry] })
    let service = MLXOpenAIService(engine: engine)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
            group.addTask {
                let hit = index.isMultiple(of: 2)
                let request = OpenAIChatCompletionRequest(model: "cache-usage", messages: [
                    .init(role: .user, content: .text(hit ? "hit" : "miss")),
                ])
                let response = try await service.createChatCompletion(request: request)
                #expect(response.usage.promptTokensDetails?.cachedTokens == (hit ? 2 : 0))
                #expect(response.usage.promptTokens == 3)
                #expect(response.choices.first?.message.content == .text("OK"))
            }
        }
        try await group.waitForAll()
    }
    await bridge.shutdown()
}

private final class CacheUsageEngine: CBv2Engine {
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let hit = request.promptTokens.last == 3
        return AsyncStream { continuation in
            continuation.yield(.delta(text: "OK", tokens: [9], logprobs: nil))
            continuation.yield(.finished(reason: .stop, usage: .init(
                promptTokens: 3, completionTokens: 1, prefixCacheHitTokens: hit ? 2 : 0)))
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

private struct CacheUsageTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, text == "hit" ? 3 : 4] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "OK" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        [1, 2, (messages.last?["content"] as? String) == "hit" ? 3 : 4]
    }
}

@Test("local transport cancellation reaches its admitted native row while no tokens are emitted")
func localDisconnectCancelsQuietNativeRow() async throws {
    let native = QuietCancellationEngine()
    let tokenizer = TokenizerHandle(CacheUsageTokenizer())
    let bridge = EngineV2Bridge(engine: native, modelId: "quiet", tokenizer: tokenizer, eosTokenIds: [])
    let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: tokenizer, engineV2Bridge: bridge)
    let engine = MultiModelBatchSchedulerEngine(registryProvider: { ["quiet": entry] })
    let scope = LocalRequestCancellationScope()
    let events = try await LocalRequestCancellation.$current.withValue(scope) {
        try await engine.streamChatCompletion(request: .init(model: "quiet",
            messages: [.init(role: .user, content: .text("wait"))]))
    }
    #expect(scope.registrationCount == 1)
    let consumer = Task<Void, Never> {
        do { for try await _ in events {} } catch {}
    }
    scope.cancel()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while native.cancelCount == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(native.cancelCount == 1)
    if native.cancelCount == 0 { consumer.cancel() }
    await consumer.value
    #expect(native.outstanding == 0)
    #expect(scope.registrationCount == 0)
    await bridge.shutdown()
}

private final class QuietCancellationEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var cancellations = 0
    var cancelCount: Int { lock.withLock { cancellations } }
    var outstanding: Int { lock.withLock { streams.count } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in lock.withLock { streams[request.id] = continuation } }
    }
    func cancel(_ id: CBv2RequestID) {
        let stream = lock.withLock {
            let stream = streams.removeValue(forKey: id)
            if stream != nil { cancellations += 1 }
            return stream
        }
        stream?.yield(.finished(reason: .cancelled, usage: .init(promptTokens: 3, completionTokens: 0)))
        stream?.finish()
    }
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: outstanding, waitingRequests: 0, kvBytesInUse: 0,
              kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {
        let ids = lock.withLock { Array(streams.keys) }
        for id in ids { cancel(id) }
    }
}
