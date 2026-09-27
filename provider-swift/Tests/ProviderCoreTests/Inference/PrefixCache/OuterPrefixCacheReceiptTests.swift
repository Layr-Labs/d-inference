import Foundation
import Testing

@testable import ProviderCore

@Suite("Outer inference-handler prefix cache receipts")
struct OuterPrefixCacheReceiptTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [OutboundMessage] = []

        func append(_ message: OutboundMessage) {
            lock.withLock { messages.append(message) }
        }

        var lookups: [(outcome: PrefixCacheLookupOutcome, tier: PrefixCacheTier?)] {
            lock.withLock {
                messages.compactMap {
                    guard case .prefixCacheLookup(
                        _, _, let outcome, let tier, _, _, _
                    ) = $0 else { return nil }
                    return (outcome, tier)
                }
            }
        }

        var kinds: [String] {
            lock.withLock {
                messages.compactMap {
                    switch $0 {
                    case .prefixCacheLookup: return "lookup"
                    case .inferenceError: return "error"
                    case .inferenceComplete: return "complete"
                    default: return nil
                    }
                }
            }
        }

    }

    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5",
                chipName: "Apple M4 Max",
                chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128,
                memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40,
                memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "outer-receipt-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(
            config: config,
            purgeLegacyFiles: false,
            attestationSigner: nil)
    }

    @Test("pre-decrypt policy failure emits exactly one lookup receipt")
    func malformedResponseKeyFinalizesPolicy() async throws {
        let loop = try makeLoop()
        let recorder = Recorder()
        await loop.handleInferenceRequest(
            requestId: "outer-policy",
            ciphertext: Data(),
            senderPublicKey: nil,
            cacheReceiptNonce: "nonce-policy",
            authenticatedCacheScope: "scope-policy",
            send: SendHandle(recorder.append))
        #expect(recorder.lookups.count == 1)
        #expect(recorder.lookups.first?.outcome == .skippedPolicy)
        #expect(recorder.kinds == ["lookup", "error"])
    }

    @Test("pre-decrypt shutdown admission emits exactly one capacity receipt")
    func shutdownFinalizesCapacity() async throws {
        let loop = try makeLoop()
        await loop.beginShutdownForTesting()
        let recorder = Recorder()
        await loop.handleInferenceRequest(
            requestId: "outer-capacity",
            ciphertext: Data(),
            senderPublicKey: nil,
            cacheReceiptNonce: "nonce-capacity",
            authenticatedCacheScope: "scope-capacity",
            send: SendHandle(recorder.append))
        #expect(recorder.lookups.count == 1)
        #expect(recorder.lookups.first?.outcome == .skippedCapacity)
        #expect(recorder.kinds == ["lookup", "error"])
    }

    @Test("bridge resolution wins over the outer policy backstop without duplication")
    func bridgeResolutionIsSetOnce() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [PrefixCacheLookupResult] = []
        }
        let box = Box()
        let finalizer = PrefixCacheLookupReceiptFinalizer(callback: { value in
            box.lock.withLock { box.values.append(value) }
        })
        finalizer.resolve(PrefixCacheLookupResult(
            outcome: .hit,
            tier: .ssd,
            cachedTokens: 64,
            prefillTokensSaved: 48))
        finalizer.finalize(failure: .policy)
        #expect(box.lock.withLock { box.values.count } == 1)
        #expect(box.lock.withLock { box.values.first?.outcome } == .hit)
    }

    @Test("detached terminal helper queues lookup before error without duplicate")
    func detachedFailureOrdering() async throws {
        let recorder = Recorder()
        let send = SendHandle(recorder.append)
        let callbacks = PrefixCacheReceiptEmitter.callbacks(
            requestID: "detached-order",
            nonce: "detached-nonce",
            send: send)
        let finalizer = PrefixCacheLookupReceiptFinalizer(
            callback: callbacks.lookup)

        await Task.detached {
            finalizer.sendTerminal(
                .inferenceError(
                    requestId: "detached-order",
                    failure: InferenceFailure(code: .internalFailure, statusCode: 500)),
                fallbackFailure: .policy,
                send: send)
            // Detached-task defer fallback after the terminal must be a no-op.
            finalizer.finalize(failure: .policy)
        }.value

        #expect(recorder.lookups.count == 1)
        #expect(recorder.kinds == ["lookup", "error"])
    }
}
