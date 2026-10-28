import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Native terminal versus provider resource retirement", .serialized)
struct NativeBlockRetirementBridgeTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var entered = false
        private var starts = 0
        func first() -> Bool { lock.withLock { starts += 1; return starts == 1 } }
        func block() { lock.withLock { entered = true }; semaphore.wait() }
        var isEntered: Bool { lock.withLock { entered } }
        func release() { semaphore.signal() }
    }
    private struct Tokens: Tokenizer {
        var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map(Int.init) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            String(decoding: tokenIds.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
        }
        func convertTokenToId(_ token: String) -> Int? { token.utf8.first.map(Int.init) }
        func convertIdToToken(_ id: Int) -> String? { decode(tokenIds: [id], skipSpecialTokens: false) }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
    }
    private final class Session: CBv2NativeBlockSession {
        let gate: Gate?
        let cancellation: CBv2NativeBlockCancellation
        var index = 0, generatedTokenCount = 0
        var closed = false
        var retainedBytes: Int { closed ? 0 : 64 }
        var activeTokenCount: Int { 1 + generatedTokenCount }
        init(gate: Gate?, cancellation: CBv2NativeBlockCancellation) {
            self.gate = gate; self.cancellation = cancellation
        }
        func cancel() { closed = true }
        func advanceNative() throws -> CBv2NativeBlockStep {
            defer { index += 1 }
            if index == 0 { return .prefill(computedTokens: 1, complete: true) }
            if index == 2 { gate?.block() }
            if cancellation.isCancelled { throw CancellationError() }
            generatedTokenCount += 1
            return .committed(tokens: [64 + index], stopToken: nil, finishReason: index == 2 ? .length : nil)
        }
    }
    /// Commits one block of output, then stops at the token limit.
    private final class TextSession: CBv2NativeBlockSession {
        let tokens: [Int]
        let cancellation: CBv2NativeBlockCancellation
        var index = 0, generatedTokenCount = 0
        var retainedBytes: Int { 64 }
        var activeTokenCount: Int { 1 + generatedTokenCount }
        init(tokens: [Int], cancellation: CBv2NativeBlockCancellation) {
            self.tokens = tokens; self.cancellation = cancellation
        }
        func cancel() {}
        func advanceNative() throws -> CBv2NativeBlockStep {
            defer { index += 1 }
            if index == 0 { return .prefill(computedTokens: 1, complete: true) }
            if cancellation.isCancelled { throw CancellationError() }
            if index == 1 {
                generatedTokenCount = tokens.count
                return .committed(tokens: tokens, stopToken: nil, finishReason: nil)
            }
            return .committed(tokens: [], stopToken: nil, finishReason: .length)
        }
    }
    private struct Result: Sendable { var text = "", error = ""; var cause: InferenceTerminalCause?; var completion = 0 }
    private func collect(_ stream: AsyncStream<GenerationEvent>) async -> Result {
        var result = Result()
        for await event in stream {
            switch event {
            case .chunk(let text): result.text += text
            case .info(_, let completion, _, _): result.completion = completion
            case .error(let message): result.error = message
            case .terminal(let cause, _, _, let completion): result.cause = cause; result.completion = completion
            }
        }
        return result
    }
    private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await predicate())
    }

    /// The native block decoder matches stops over the whole output, so a
    /// request's reasoning scope is not sent there and the reported stop is
    /// the one that matched.
    @Test func nativeBlockRequestsCarryNoStopScope() async throws {
        let tokenizer = Tokens()
        let output = Array("<|channel>thought\nIt is A.<channel|>Yes!".utf8).map(Int.init)
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 300,
            shutdownGraceSeconds: 0, loopConfig: .init(stepTimeout: 60, watchdogInterval: 0.01),
            reservationForRequest: { _ in 100 }, makeSession: { _, cancellation in
                TextSession(tokens: output, cancellation: cancellation)
            })
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 1_000)
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: "native-fixture", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 64, kvBytesPerToken: 1, kvBudget: budget)
        let request = ChatCompletionRequest(model: "native-fixture", messages: [], temperature: 1, max_tokens: 64,
            stop: .multiple([".", "!"]))
        let signal = EngineV2RequestUsageSignal()
        let result = await collect(await bridge.submitTokenized(promptTokens: [1], request: request,
            requestId: "scoped", cacheEnabled: false, usageSignal: signal,
            stopStringScope: ReasoningStopScope.scope(reasoningParser: .gemma4, reasoningPrefix: nil)))
        #expect(result.text == "<|channel>thought\nIt is A" && result.error.isEmpty)
        #expect(signal.matchedStopSequence == ".")
        await bridge.shutdown()
    }

    @Test func watchdogReturnsTypedErrorWithoutRefundingBlockedNativeMemory() async throws {
        try await exercise(cancelConsumer: false)
    }
    @Test func ordinaryConsumerCancellationStillReachesTheNativeEngine() async throws {
        try await exercise(cancelConsumer: true)
    }
    private func exercise(cancelConsumer: Bool) async throws {
        let gate = Gate(), tokenizer = Tokens()
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 300,
            shutdownGraceSeconds: 0,
            loopConfig: .init(stepTimeout: cancelConsumer ? 60 : 0.1, watchdogInterval: 0.01),
            reservationForRequest: { _ in 100 }, makeSession: { _, cancellation in
                Session(gate: gate.first() ? gate : nil, cancellation: cancellation)
            })
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 1_000)
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: "native-fixture", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 2, kvBytesPerToken: 1, kvBudget: budget)
        let request = ChatCompletionRequest(model: "native-fixture", messages: [], temperature: 1, max_tokens: 2)
        defer { gate.release() }
        do {
            let stream = await bridge.submitTokenized(promptTokens: [1], request: request,
                requestId: "held", cacheEnabled: false)
            let consumer = Task { await collect(stream) }
            try await eventually { gate.isEntered }
            if cancelConsumer { consumer.cancel() }
            let result = await consumer.value
            if !cancelConsumer {
                #expect(result.cause == .watchdog && result.completion == 1 && result.text == "A")
                #expect(await bridge.backendSlotCapacity().state == "crashed")
            }
            #expect(await budget.outstandingReservedBytes() == 100)
            #expect(engine.capacity().kvBytesReserved == 100)
            #expect(await bridge.activeRequestCount() == 1, "A still-owned native row is not evictable")
            let duplicate = await collect(await bridge.submitTokenized(promptTokens: [1], request: request,
                requestId: "held", cacheEnabled: false))
            #expect(duplicate.error.contains("duplicate request ID"))
            #expect(await budget.outstandingReservedBytes() == 100)
            gate.release()
            try await eventually {
                let bytes = await budget.outstandingReservedBytes()
                let pending = await bridge.pendingSubmissionIDs.contains("held")
                return bytes == 0 && !pending && engine.capacity().kvBytesReserved == 0
            }
            let retried = await collect(await bridge.submitTokenized(promptTokens: [1], request: request,
                requestId: "held", cacheEnabled: false))
            #expect(retried.text == "AB" && retried.completion == 2 && retried.error.isEmpty)
            await bridge.shutdown()
            #expect(await budget.outstandingReservedBytes() == 0)
        } catch { gate.release(); await bridge.shutdown(); throw error }
    }
}
