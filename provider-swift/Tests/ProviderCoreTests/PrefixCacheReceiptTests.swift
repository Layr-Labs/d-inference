import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Provider-confirmed prefix cache receipts")
struct PrefixCacheReceiptTests {
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

        // Standalone/local callers retain their configured/default behavior.
        let localDefault = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(3),
            promptTokens: [1],
            request: request,
            defaultMaxTokens: 8,
            stopTokenIds: [])
        #expect(localDefault.prefixCacheEnabled)
        #expect(request.cacheScope == ChatCompletionRequest.scopeHash("caller-controlled"))
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
            error: "terminal",
            statusCode: 500,
            errorReason: nil))

        #expect(sequence.lock.withLock { sequence.values } == ["lookup", "ready", "error"])
    }

    @Test("early prompt donation is opt-in and parses explicit affirmative values")
    func earlyDonationFlag() {
        #expect(!EngineV2Factory.earlyPrefixDonationEnabled(environment: [:]))
        #expect(!EngineV2Factory.earlyPrefixDonationEnabled(
            environment: ["DARKBLOOM_EARLY_PROMPT_DONATION": "0"]))
        #expect(!EngineV2Factory.earlyPrefixDonationEnabled(
            environment: ["DARKBLOOM_EARLY_PROMPT_DONATION": "typo"]))
        for value in ["1", "true", "YES", " on "] {
            #expect(EngineV2Factory.earlyPrefixDonationEnabled(
                environment: ["DARKBLOOM_EARLY_PROMPT_DONATION": value]))
        }
        #expect(!EngineV2Factory.productionLoopConfig(environment: [:]).enableEarlyPrefixDonation)
        #expect(EngineV2Factory.productionLoopConfig(environment: [
            "DARKBLOOM_EARLY_PROMPT_DONATION": "1",
        ]).enableEarlyPrefixDonation)
    }
}
