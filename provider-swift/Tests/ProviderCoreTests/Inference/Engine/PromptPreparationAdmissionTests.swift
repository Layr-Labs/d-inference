import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Renders every conversation to `count` tokens and counts the renders. With
/// `holdsFirstRender`, the first render waits for `releaseFirstRender`; with
/// `failsRenders`, every render throws.
final class CountingRenderTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    struct RenderFailure: Error {}

    private let lock = NSLock()
    private var calls = 0
    private let count: Int
    private let holdsFirstRender: Bool
    private let failsRenders: Bool
    private let gate = DispatchSemaphore(value: 0)

    init(count: Int = 8, holdsFirstRender: Bool = false, failsRenders: Bool = false) {
        self.count = count
        self.holdsFirstRender = holdsFirstRender
        self.failsRenders = failsRenders
    }

    var renders: Int { lock.withLock { calls } }
    func releaseFirstRender() { gate.signal() }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: count) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        let call = lock.withLock { calls += 1; return calls }
        if holdsFirstRender, call == 1 { _ = gate.wait(timeout: .now() + 20) }
        if failsRenders { throw RenderFailure() }
        return Array(repeating: 1, count: count)
    }
}

/// Counts the requests submitted to it and answers each with one token and a
/// `.finished(.stop)` terminal, so a served request completes without error.
final class PreparationTestEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var submissions: Int { lock.withLock { count } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { count += 1 }
        return AsyncStream { continuation in
            continuation.yield(.delta(text: "OK", tokens: [9], logprobs: nil))
            continuation.yield(.finished(reason: .stop, usage: .init(
                promptTokens: request.promptTokens.count, completionTokens: 1)))
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// A text prompt's rendering and tokenization count against the whole-Mac
/// serving width: a full Mac refuses a request as capacity before rendering
/// its prompt, a prompt being prepared holds a share another request cannot
/// take, and the share becomes the request's serving allowance at submission.
@Suite("Prompt preparation counts against the serving width")
struct PromptPreparationAdmissionTests {
    private static let model = "preparation/model"
    private static let width = ServingPerformanceProfiles.legacyWholeMacConcurrency

    private struct Served: Sendable {
        let engine: PreparationTestEngine
        let serviceBudget: WholeMacServiceBudget
        let bridge: EngineV2Bridge
        let scheduler: MultiModelBatchSchedulerEngine

        /// `busy` of the whole-Mac width's shares are held by other requests.
        init(tokenizer: CountingRenderTokenizer, busy: Int) {
            let model = PromptPreparationAdmissionTests.model
            let width = PromptPreparationAdmissionTests.width
            let engine = PreparationTestEngine()
            let budget = roomyKVBudget()
            for slot in 0..<busy {
                precondition(budget.serviceBudget.acquire(ownerID: "busy-\(slot)", concurrency: width))
            }
            let handle = TokenizerHandle(tokenizer)
            let bridge = EngineV2Bridge(engine: engine, modelId: model, tokenizer: handle, eosTokenIds: [],
                defaultMaxTokens: 64, maxConcurrentRequests: 1, kvBudget: budget)
            self.engine = engine
            serviceBudget = budget.serviceBudget
            self.bridge = bridge
            scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
                [model: .init(tokenizer: handle, modelType: "llama", engineV2Bridge: bridge)]
            })
        }

        /// Nil when the request completed; else what it threw.
        func complete() async -> (any Error)? {
            do {
                let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
                {"model":"\(PromptPreparationAdmissionTests.model)","messages":[{"role":"user","content":"hi"}],"max_tokens":16}
                """.utf8))
                for try await _ in try await scheduler.streamChatCompletion(request: request) {}
                return nil
            } catch { return error }
        }

        /// The budget once every finished request's allowance has retired.
        func settledCount(_ expected: Int) async -> Int {
            for _ in 0..<500 where serviceBudget.count != expected {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return serviceBudget.count
        }
    }

    private static let capacity = MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
        EngineV2Bridge.serviceAllowanceExhausted)

    @Test("a full Mac refuses a request as capacity before rendering its prompt")
    func aFullMacRefusesBeforeRendering() async throws {
        let tokenizer = CountingRenderTokenizer()
        let served = Served(tokenizer: tokenizer, busy: Self.width)
        let error = await served.complete()
        #expect(error as? MultiModelBatchSchedulerEngineError == Self.capacity)
        #expect(tokenizer.renders == 0)
        #expect(served.engine.submissions == 0)
        #expect(await served.settledCount(Self.width) == Self.width)
        await served.bridge.shutdown()
    }

    @Test("a prompt being prepared holds the last share: another request is refused before rendering",
          .timeLimit(.minutes(1)))
    func aPreparingPromptHoldsItsShare() async throws {
        let tokenizer = CountingRenderTokenizer(holdsFirstRender: true)
        let served = Served(tokenizer: tokenizer, busy: Self.width - 1)
        let first = Task { await served.complete() }
        while tokenizer.renders == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = await served.complete()
        let rendersWhileHeld = tokenizer.renders
        tokenizer.releaseFirstRender()
        let firstError = await first.value
        #expect(second as? MultiModelBatchSchedulerEngineError == Self.capacity)
        #expect(rendersWhileHeld == 1)
        #expect(firstError == nil)
        #expect(served.engine.submissions == 1)
        #expect(await served.settledCount(Self.width - 1) == Self.width - 1)
        await served.bridge.shutdown()
    }

    @Test("a prompt prepared on the last share is served on it, and the share retires with the request")
    func theLastShareIsServed() async throws {
        let tokenizer = CountingRenderTokenizer()
        let served = Served(tokenizer: tokenizer, busy: Self.width - 1)
        #expect(await served.complete() == nil)
        #expect(tokenizer.renders == 1)
        #expect(served.engine.submissions == 1)
        #expect(await served.settledCount(Self.width - 1) == Self.width - 1)
        // The share is free again: the next request is served on it.
        #expect(await served.complete() == nil)
        #expect(served.engine.submissions == 2)
        await served.bridge.shutdown()
    }

    @Test("a prompt that fails to render returns its share")
    func aFailedRenderReturnsItsShare() async throws {
        let tokenizer = CountingRenderTokenizer(failsRenders: true)
        let served = Served(tokenizer: tokenizer, busy: Self.width - 1)
        #expect(await served.complete() != nil)
        #expect(await served.complete() != nil)
        // Both rendered: the first failure left the last share free.
        #expect(tokenizer.renders == 2)
        #expect(served.engine.submissions == 0)
        #expect(await served.settledCount(Self.width - 1) == Self.width - 1)
        await served.bridge.shutdown()
    }
}
