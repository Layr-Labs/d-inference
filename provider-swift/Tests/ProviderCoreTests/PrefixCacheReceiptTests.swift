import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Provider-confirmed prefix cache receipts")
struct PrefixCacheReceiptTests {
    private final class V2Messages: @unchecked Sendable {
        let lock = NSLock()
        var values: [OutboundMessage] = []
    }

    @Test("remote scope is authenticated outer metadata; absence disables cache")
    func remoteScopePolicy() {
        let present = RemotePrefixCacheContext(
            cacheScope: "coordinator-account-scope",
            cacheReceiptNonce: "nonce")
        #expect(present.cacheEnabled)
        #expect(present.scope == "coordinator-account-scope")
        #expect(present.receiptNonce == "nonce")

        let absent = RemotePrefixCacheContext(
            cacheScope: nil,
            cacheReceiptNonce: "nonce")
        #expect(!absent.cacheEnabled)
        #expect(absent.scope == nil)
        #expect(absent.receiptNonce == "nonce")

        let blank = RemotePrefixCacheContext(cacheScope: "  \n", cacheReceiptNonce: " ")
        #expect(!blank.cacheEnabled)
        #expect(blank.receiptNonce == nil)
    }

    @Test("request translation carries explicit cache disable while local defaults enabled")
    func translationPolicy() {
        let request = ChatCompletionRequest(
            model: "m",
            messages: [ChatMessage(role: "user", content: "hello")],
            prompt_cache_key: "caller-controlled")
        let remoteDisabled = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(1),
            promptTokens: [1, 2, 3],
            request: request,
            defaultMaxTokens: 8,
            stopTokenIds: [],
            cacheScope: "",
            cacheEnabled: false)
        #expect(!remoteDisabled.prefixCacheEnabled)
        #expect(remoteDisabled.cacheSalt == nil)

        let remoteScoped = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(2),
            promptTokens: [1, 2, 3],
            request: request,
            defaultMaxTokens: 8,
            stopTokenIds: [],
            cacheScope: "authenticated-outer",
            cacheEnabled: true)
        #expect(remoteScoped.prefixCacheEnabled)
        #expect(remoteScoped.cacheSalt == "authenticated-outer")

        // Standalone/local callers are unscoped even when the body carries a
        // caller-controlled compatibility field.
        let localDefault = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(3),
            promptTokens: [1],
            request: request,
            defaultMaxTokens: 8,
            stopTokenIds: [])
        #expect(localDefault.prefixCacheEnabled)
        #expect(localDefault.cacheSalt == nil)
    }

    @Test("engine terminal distinguishes matched prefix from prefill saved")
    func matchedVersusSaved() throws {
        let signal = EngineV2RequestUsageSignal()
        signal.record(usage: CBv2Usage(
            promptTokens: 5000,
            completionTokens: 1,
            prefixCacheOutcome: .hit,
            prefixCacheMatchedTokens: 4096,
            prefixCachePrefillTokensSaved: 2560))
        let result = try #require(signal.lookupResult)
        #expect(result.outcome == .hit)
        #expect(result.cachedTokens == 4096)
        #expect(result.prefillTokensSaved == 2560)
    }

    @Test("engine outcomes map precisely; adoption failure is conservative policy")
    func outcomeMapping() throws {
        for (engine, wire) in [
            (CBv2PrefixCacheOutcome.miss, PrefixCacheLookupOutcome.missAbsent),
            (.skippedCapacity, .skippedCapacity),
            (.skippedPolicy, .skippedPolicy),
            (.adoptionFailed, .skippedPolicy),
            (.disabled, .skippedPolicy),
        ] {
            let signal = EngineV2RequestUsageSignal()
            signal.record(usage: CBv2Usage(
                promptTokens: 10,
                completionTokens: 1,
                prefixCacheOutcome: engine))
            #expect(try #require(signal.lookupResult).outcome == wire)
        }
    }

    @Test("lookup callback is exactly once and runs after result publication")
    func lookupExactlyOnce() throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [PrefixCacheLookupResult] = []
        }
        let box = Box()
        let signal = EngineV2RequestUsageSignal { result in
            box.lock.withLock { box.values.append(result) }
        }
        let usage = CBv2Usage(
            promptTokens: 100,
            completionTokens: 1,
            prefixCacheOutcome: .hit,
            prefixCacheMatchedTokens: 64,
            prefixCachePrefillTokensSaved: 48)
        signal.record(usage: usage)
        signal.record(usage: usage)
        #expect(box.lock.withLock { box.values.count } == 1)
        #expect(signal.lookupResult?.cachedTokens == 64)
    }

    @Test("failure finalization uses known stage result and remains exactly once")
    func failureFinalization() throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [PrefixCacheLookupResult] = []
        }
        let cases: [(SSDPrefixCacheStageDisposition, PrefixCacheLookupFailureClass,
            PrefixCacheLookupOutcome)] = [
            (.missAbsent, .capacity, .missAbsent),
            (.missCorrupt, .policy, .missCorrupt),
            (.skippedCost, .capacity, .skippedCost),
            (.skippedCapacity, .policy, .skippedCapacity),
            (.skippedPolicy, .capacity, .skippedPolicy),
            (.staged(
                matchedTokens: 64,
                expectedPrefillTokensSaved: 48,
                shortenedByCorruption: false), .capacity, .skippedCapacity),
            (.staged(
                matchedTokens: 64,
                expectedPrefillTokensSaved: 48,
                shortenedByCorruption: false), .policy, .skippedPolicy),
        ]
        for (stage, failure, expected) in cases {
            let box = Box()
            let signal = EngineV2RequestUsageSignal { result in
                box.lock.withLock { box.values.append(result) }
            }
            signal.record(stageResult: SSDPrefixCacheStageResult(
                disposition: stage, stageMs: 2.5))
            signal.finalizeLookup(failure: failure, fallbackTier: .memory)
            signal.finalizeLookup(failure: failure, fallbackTier: .memory)
            signal.record(usage: CBv2Usage(
                promptTokens: 10,
                completionTokens: 0,
                prefixCacheOutcome: .miss))
            let values = box.lock.withLock { box.values }
            #expect(values.count == 1)
            #expect(try #require(values.first).outcome == expected)
            #expect(values.first?.tier == .ssd)
            #expect(values.first?.stageMs == 2.5)
        }
    }

    @Test("missing-stage and cache-disabled attempts finalize once")
    func missingStageFinalization() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [PrefixCacheLookupResult] = []
        }
        let box = Box()
        let signal = EngineV2RequestUsageSignal { result in
            box.lock.withLock { box.values.append(result) }
        }
        signal.finalizeLookup(failure: .capacity, fallbackTier: .memory)
        signal.recordCacheDisabled(tier: .memory)
        signal.record(usage: CBv2Usage(promptTokens: 1, completionTokens: 0))
        let values = box.lock.withLock { box.values }
        #expect(values.count == 1)
        #expect(values.first?.outcome == .skippedCapacity)
        #expect(values.first?.tier == .memory)
    }

    @Test("ready stage cost is optional, finite, and bounded")
    func readyStageCostBounds() {
        func result(_ stageMs: Double?) -> PrefixCacheReadyResult {
            PrefixCacheReadyResult(
                readyTokens: 8,
                requiredRecomputeTokens: 0,
                expectedPrefillTokensSaved: 8,
                stageMs: stageMs)
        }
        #expect(result(nil).stageMs == nil)
        #expect(result(.nan).stageMs == nil)
        #expect(result(.infinity).stageMs == nil)
        #expect(result(-1).stageMs == 0)
        #expect(result(PrefixCacheReadyResult.maxStageMs + 1).stageMs
            == PrefixCacheReadyResult.maxStageMs)
    }

    @Test("lookup and ready receipts are synchronously queued before terminal error")
    func receiptOrderingBeforeTerminal() throws {
        final class Sequence: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
        }
        let sequence = Sequence()
        let send = SendHandle { message in
            let kind: String
            switch message {
            case .prefixCacheLookup: kind = "lookup"
            case .prefixCacheReady: kind = "ready"
            case .inferenceError: kind = "error"
            default: kind = "other"
            }
            sequence.lock.withLock { sequence.values.append(kind) }
        }
        let callbacks = PrefixCacheReceiptEmitter.callbacks(
            requestID: "ordered-request",
            nonce: "ordered-nonce",
            send: send)
        let lookup = try #require(callbacks.lookup)
        let ready = try #require(callbacks.ready)

        lookup(PrefixCacheLookupResult(outcome: .missAbsent, tier: .ssd))
        ready(PrefixCacheReadyResult(
            readyTokens: 64,
            requiredRecomputeTokens: 0,
            expectedPrefillTokensSaved: 64,
            stageMs: 1))
        send.send(.inferenceError(
            requestId: "ordered-request",
            failure: InferenceFailure(code: .internalFailure, statusCode: 500)))

        #expect(sequence.lock.withLock { sequence.values } == ["lookup", "ready", "error"])
    }

    @Test("concurrent terminal waits until the claimed lookup is queued")
    func concurrentLookupClaimCannotBeOvertakenByTerminal() {
        final class Sequence: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
        }
        let callbackEntered = DispatchSemaphore(value: 0)
        let allowCallbackToQueue = DispatchSemaphore(value: 0)
        let terminalWaiting = DispatchSemaphore(value: 0)
        let lookupReturned = DispatchSemaphore(value: 0)
        let terminalReturned = DispatchSemaphore(value: 0)
        let sequence = Sequence()
        let send = SendHandle { message in
            let kind: String
            switch message {
            case .prefixCacheLookup: kind = "lookup"
            case .inferenceError: kind = "error"
            default: kind = "other"
            }
            sequence.lock.withLock { sequence.values.append(kind) }
        }
        let finalizer = PrefixCacheLookupReceiptFinalizer(callback: { _ in
            callbackEntered.signal()
            allowCallbackToQueue.wait()
            send.send(.prefixCacheLookup(
                requestId: "concurrent-request",
                cacheReceiptNonce: "nonce",
                outcome: .missAbsent,
                tier: .ssd,
                cachedTokens: nil,
                prefillTokensSaved: nil,
                stageMs: nil))
        }, deliveryWaitObserver: {
            terminalWaiting.signal()
        })

        let lookupThread = Thread {
            finalizer.resolve(PrefixCacheLookupResult(outcome: .missAbsent, tier: .ssd))
            lookupReturned.signal()
        }
        lookupThread.start()
        #expect(callbackEntered.wait(timeout: .now() + 1) == .success)

        let terminalThread = Thread {
            finalizer.sendTerminal(
                .inferenceError(
                    requestId: "concurrent-request",
                    failure: InferenceFailure(code: .internalFailure, statusCode: 500)),
                fallbackFailure: .policy,
                tier: .ssd,
                send: send)
            terminalReturned.signal()
        }
        terminalThread.start()
        #expect(terminalWaiting.wait(timeout: .now() + 5) == .success)
        #expect(sequence.lock.withLock { sequence.values.isEmpty })

        allowCallbackToQueue.signal()
        #expect(lookupReturned.wait(timeout: .now() + 5) == .success)
        #expect(terminalReturned.wait(timeout: .now() + 5) == .success)
        #expect(sequence.lock.withLock { sequence.values } == ["lookup", "error"])
    }

    @Test("v2 sequencer buffers ready, orders terminal, and assigns strict sequence")
    func v2SequencerOrdering() async throws {
        let capability = v2Capability(epoch: "11111111-1111-1111-1111-111111111111")
        let sequencer = PrefixCacheEvidenceSequencer { capability }
        defer { sequencer.shutdown() }
        let messages = V2Messages()
        let send = SendHandle { message in
            messages.lock.withLock { messages.values.append(message) }
        }
        let callbacks = try #require(sequencer.callbacks(
            requestID: "request",
            nonce: "nonce",
            send: send))
        let prompt = PrefixCacheAnchor(chainHash: String(repeating: "c", count: 64), tokenCount: 256)
        let final = PrefixCacheAnchor(chainHash: String(repeating: "d", count: 64), tokenCount: 512)

        callbacks.ready(PrefixCacheReadyResult(
            readyTokens: 512,
            requiredRecomputeTokens: 256,
            expectedPrefillTokensSaved: 256,
            stageMs: 2,
            finalAnchor: final))
        callbacks.lookup(PrefixCacheLookupResult(
            outcome: .missAbsent,
            tier: .ssd,
            stageMs: 1,
            promptAnchor: prompt))
        callbacks.terminal(.inferenceError(
            requestId: "request",
            failure: InferenceFailure(code: .internalFailure, statusCode: 500)))

        await waitForMessages(messages, count: 3)
        let values = messages.lock.withLock { messages.values }
        #expect(values.count == 3)
        if values.count == 3 {
            guard case .prefixCacheLookupV2(let lookup) = values[0],
                case .prefixCacheReadyV2(let ready) = values[1],
                case .inferenceError = values[2]
            else {
                Issue.record("unexpected v2 message ordering")
                return
            }
            #expect(lookup.cacheSeq == 1)
            #expect(ready.cacheSeq == 2)
            #expect(ready.readyAnchors == [prompt, final])
        }
    }

    @Test("v2 sequence stays strictly monotonic under concurrent callbacks")
    func v2SequencerConcurrency() async throws {
        let capability = v2Capability(epoch: "11111111-1111-1111-1111-111111111111")
        let sequencer = PrefixCacheEvidenceSequencer { capability }
        defer { sequencer.shutdown() }
        let messages = V2Messages()
        let send = SendHandle { message in
            messages.lock.withLock { messages.values.append(message) }
        }
        let prompt = PrefixCacheAnchor(
            chainHash: String(repeating: "c", count: 64),
            tokenCount: 256)
        let callbacks = try (0 ..< 32).map { index in
            try #require(sequencer.callbacks(
                requestID: "request-\(index)",
                nonce: "nonce-\(index)",
                send: send))
        }
        await withTaskGroup(of: Void.self) { group in
            for callback in callbacks {
                group.addTask {
                    callback.lookup(PrefixCacheLookupResult(
                        outcome: .missAbsent,
                        tier: .ssd,
                        promptAnchor: prompt))
                }
            }
        }
        await waitForMessages(messages, count: callbacks.count)
        let sequences = messages.lock.withLock {
            messages.values.compactMap { message -> UInt64? in
                guard case .prefixCacheLookupV2(let lookup) = message else { return nil }
                return lookup.cacheSeq
            }
        }
        #expect(sequences == Array(1 ... UInt64(callbacks.count)))
    }

    @Test("v2 proof mismatch drops evidence but preserves terminal fallback")
    func v2ProofMismatchFallback() async throws {
        let capability = v2Capability(epoch: "11111111-1111-1111-1111-111111111111")
        let sequencer = PrefixCacheEvidenceSequencer { capability }
        defer { sequencer.shutdown() }
        let messages = V2Messages()
        let send = SendHandle { message in
            messages.lock.withLock { messages.values.append(message) }
        }
        let callbacks = try #require(sequencer.callbacks(
            requestID: "request",
            nonce: "nonce",
            send: send))
        callbacks.lookup(PrefixCacheLookupResult(
            outcome: .hit,
            tier: .ssd,
            cachedTokens: 256,
            prefillTokensSaved: 255,
            promptAnchor: PrefixCacheAnchor(
                chainHash: String(repeating: "c", count: 64),
                tokenCount: 256),
            matchedAnchor: PrefixCacheAnchor(
                chainHash: String(repeating: "c", count: 64),
                tokenCount: 256),
            requiredRecomputeTokens: 0))
        callbacks.terminal(.inferenceError(
            requestId: "request",
            failure: InferenceFailure(code: .internalFailure, statusCode: 500)))

        await waitForMessages(messages, count: 1)
        let values = messages.lock.withLock { messages.values }
        #expect(values.count == 1)
        if let only = values.first {
            guard case .inferenceError = only else {
                Issue.record("proof mismatch emitted cache evidence")
                return
            }
        }
    }

    @Test("v2 sequencer invalidates callbacks across epoch rollover")
    func v2SequencerEpochRollover() async throws {
        final class CapabilityBox: @unchecked Sendable {
            let lock = NSLock()
            var value: PrefixCacheV2Capability?
        }
        final class SequenceBox: @unchecked Sendable {
            let lock = NSLock()
            var sequences: [UInt64] = []
        }
        let box = CapabilityBox()
        box.value = v2Capability(epoch: "11111111-1111-1111-1111-111111111111")
        let sequencer = PrefixCacheEvidenceSequencer {
            box.lock.withLock { box.value }
        }
        defer { sequencer.shutdown() }
        let sequences = SequenceBox()
        let send = SendHandle { message in
            if case .prefixCacheLookupV2(let lookup) = message {
                sequences.lock.withLock { sequences.sequences.append(lookup.cacheSeq) }
            }
        }
        let old = try #require(sequencer.callbacks(
            requestID: "old", nonce: "old", send: send))
        box.lock.withLock {
            box.value = v2Capability(epoch: "22222222-2222-2222-2222-222222222222")
        }
        let current = try #require(sequencer.callbacks(
            requestID: "new", nonce: "new", send: send))
        let prompt = PrefixCacheAnchor(chainHash: String(repeating: "c", count: 64), tokenCount: 256)
        old.lookup(PrefixCacheLookupResult(
            outcome: .missAbsent, tier: .ssd, promptAnchor: prompt))
        current.lookup(PrefixCacheLookupResult(
            outcome: .missAbsent, tier: .ssd, promptAnchor: prompt))

        for _ in 0 ..< 100 where sequences.lock.withLock({ sequences.sequences.count }) < 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(sequences.lock.withLock { sequences.sequences } == [1])
    }

    private func v2Capability(epoch: String) -> PrefixCacheV2Capability {
        PrefixCacheV2Capability(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64),
            blockHashVersion: "dbk3",
            blockSize: 256,
            cacheEpoch: epoch,
            enabled: true,
            ready: true)
    }

    private func waitForMessages(
        _ box: V2Messages,
        count: Int
    ) async {
        for _ in 0 ..< 100 {
            if box.lock.withLock({ box.values.count }) >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

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
}
