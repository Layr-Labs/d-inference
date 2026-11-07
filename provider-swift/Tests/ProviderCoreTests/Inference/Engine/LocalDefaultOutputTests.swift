import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A request that names no `max_tokens` (a curl or SDK call to this Mac's own
/// API; every coordinator request names one) may write the standard request's
/// output, as on a pair, cut to the context window its prompt leaves: never a
/// small product default, and never refused for a default it didn't ask for.
@Suite("Output of a request without max_tokens")
struct LocalDefaultOutputTests {
    private static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
        })
    }

    @Test func aRequestWithoutMaxTokensMayWriteTheStandardOutput() {
        #expect(ProviderLoop.schedulerDefaultMaxTokens == 32_768)
        #expect(StandaloneServer.slotDefaultMaxTokens == 32_768)
        #expect(DistributedEngineFactory.defaultOutputTokens == 32_768)
    }

    @Test(arguments: [
        // (prompt, the output the engine is asked for; nil: refused, as a prompt alone beyond the window is)
        (100, Optional(32_768)),
        (229_376, Optional(32_768)),
        (250_000, Optional(12_144)),
        (262_143, Optional(1)),
        (262_144, nil),
    ])
    func theDefaultIsCutToTheWindowThePromptLeaves(prompt: Int, output: Int?) async throws {
        let engine = DefaultOutputSentinelEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "context/model",
            tokenizer: TokenizerHandle(DefaultOutputTokenizer()), eosTokenIds: [],
            defaultMaxTokens: 32_768, maxConcurrentRequests: 1, kvBudget: Self.budget(),
            advertisedContextTokens: 262_144)
        do {
            let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: "context/model", messages: []), requestId: "default-output",
                firstContentDeadline: nil)
            for await _ in stream {}
            #expect(output != nil, "a prompt that fills the window reached the engine")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(output == nil && error == .advertisedContextExceeded)
        }
        #expect(engine.submittedOutputs == (output.map { [$0] } ?? []))
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }

    @Test func anExplicitMaxTokensIsNeverCut() async throws {
        let engine = DefaultOutputSentinelEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "context/model",
            tokenizer: TokenizerHandle(DefaultOutputTokenizer()), eosTokenIds: [],
            defaultMaxTokens: 32_768, maxConcurrentRequests: 1, kvBudget: Self.budget(),
            advertisedContextTokens: 262_144)
        let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 100),
            request: .init(model: "context/model", messages: [], max_tokens: 200_000), requestId: "explicit",
            firstContentDeadline: nil)
        for await _ in stream {}
        #expect(engine.submittedOutputs == [200_000])
        await bridge.shutdown()
    }
}

/// No tensors or token generation: records the output each admitted request asks for.
private final class DefaultOutputSentinelEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Int] = []
    var submittedOutputs: [Int] { lock.withLock { outputs } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { outputs.append(request.maxTokens) }
        return AsyncStream { $0.finish() }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct DefaultOutputTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "test" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
