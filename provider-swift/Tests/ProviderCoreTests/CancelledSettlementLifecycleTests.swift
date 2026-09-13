import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Scripted engine only for missing-terminal and shutdown ownership. The
/// cache-adoption regression uses the concrete native engine in its own suite.
private final class CancellationSettlementEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CBv2Event>.Continuation?
    private var cancellations = 0

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }
    func emit(_ event: CBv2Event) { lock.withLock { continuation }?.yield(event) }
    func close() { lock.withLock { continuation }?.finish() }
    func cancel(_ id: CBv2RequestID) { lock.withLock { cancellations += 1 } }
    var cancelCount: Int { lock.withLock { cancellations } }
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 1, waitingRequests: 0, kvBytesInUse: 4096,
              kvBytesCapacity: 1 << 20, activeTokens: 3, stepsExecuted: 1)
    }
    func updateKVBytesCapacity(_ bytes: Int) {}
    // Deliberately no terminal: shutdown must retire the bridge's pump itself.
    func shutdown() async {}
}

#if DEBUG
@Suite("Cancelled settlement lifecycle")
struct CancelledSettlementLifecycleTests {
    @Test("never-admitted and already-retired requests do not acquire a waiter")
    func inactiveAndCompletedObservation() async {
        for completed in [false, true] {
            let signal = EngineV2RequestUsageSignal()
            if completed {
                signal.beginTerminalObservation()
                signal.completeTerminalObservation()
                signal.completeTerminalObservation()
            }
            let done = CancelledPrefixBarrier()
            let waiter = Task {
                await signal.waitForTerminalObservation()
                done.signal()
            }
            waiter.cancel()
            #expect(await done.wait())
        }
    }

    @Test("canceled settlement survives native miss, closed stream, and engine shutdown",
          arguments: ["native_miss", "closed_stream", "shutdown"])
    func pumpRetiresCancelledWaiter(exit: String) async throws {
        let engine = CancellationSettlementEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fixture-model",
            tokenizer: TokenizerHandle(CancelledPrefixTokenizer(prompt: [1, 2, 3])),
            eosTokenIds: [], prefillDeadlineMode: .off)
        do {
            let profile = RequestProfileBuilder()
            let lookupDelivered = CancelledPrefixBarrier()
            let signal = EngineV2RequestUsageSignal(onLookupResolved: { _ in
                lookupDelivered.signal()
            })
            let stream = try await bridge.submitTokenized(
                promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: "fixture-model", messages: []),
                requestId: "native-row", usageSignal: signal,
                firstContentDeadline: nil, profile: profile)
            var iterator = stream.makeAsyncIterator()
            engine.emit(.delta(text: "a", tokens: [5], logprobs: nil))
            _ = await iterator.next()

            // The earlier coordinator-id miss keeps its original accounting-only
            // semantics. Cancellation is sent by the later settlement operation.
            #expect(await bridge.cancelIfOwned(requestId: "coordinator-row", profile: profile) == false)
            #expect(engine.cancelCount == 0)
            let waiting = CancelledPrefixBarrier()
            await bridge._testInstallCancelledSettlementHooks(
                beforeNativeTerminal: { _ in }, onSettlementWait: { waiting.signal() })
            let done = CancelledPrefixBarrier()
            let settlement = Task {
                await bridge.settleCancelledStream(profile: profile, usageSignal: signal)
                done.signal()
            }
            settlement.cancel()
            #expect(await waiting.wait())
            #expect(engine.cancelCount == 1)
            switch exit {
            case "native_miss":
                engine.emit(.finished(reason: .cancelled, usage: CBv2Usage(
                    promptTokens: 3, completionTokens: 1, prefixCacheOutcome: .miss)))
            case "closed_stream": engine.close()
            default: await bridge.shutdown()
            }
            #expect(await done.wait())
            #expect(await lookupDelivered.wait())
            #expect(signal.lookupResult?.outcome == (exit == "native_miss" ? .missAbsent : .skippedPolicy))
            #expect(signal.lookupResult?.cachedTokens == 0)
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        #expect(await bridge._testLivePumpCount() == 0)
    }
}
#endif
