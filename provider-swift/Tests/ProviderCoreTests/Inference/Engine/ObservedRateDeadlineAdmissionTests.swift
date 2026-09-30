import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Observed-rate first-content admission", .serialized)
struct ObservedRateDeadlineAdmissionTests {
    @Test("native atomic admission accepts observed-speed work and still refuses late or expired work")
    func nativeAdmissionUsesObservedRateWithoutExtendingDeadline() async throws {
        let now = ContinuousClock.now
        let model = ObservedRateDeadlineModel()
        let engine = EngineV2(model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            sampler: CBv2GreedySampler(), schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 64,
                prefillChunkSize: 64, maxConcurrentPartialPrefills: 1,
                maxWaiting: 4, enablePrefixCache: false),
            loopConfig: .init(clock: CBv2Clock { now }))
        let bridge = EngineV2Bridge(engine: engine, modelId: "observed-rate-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce)
        do {
            await bridge.updatePrefillTpsEwma(10, isolated: true)
            await bridge.updateDecodeTpsEwma(20)
            let prompt = Array(repeating: 1, count: 100)
            let request = ChatCompletionRequest(model: "observed-rate-fixture", messages: [], max_tokens: 1)
            // Five seconds already elapsed from the original twenty-second
            // budget. Ten seconds of measured work fits; the old 2x price did not.
            let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 20_000,
                receivedAt: now.advanced(by: .seconds(-5)))
            let policy = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: deadline, isMultimodal: false))
            #expect(policy.deadline == deadline.instant)
            #expect(policy.conservativePrefillTokensPerSecond == 10)
            #expect(policy.conservativeDecodeTokensPerSecond == 20)
            #expect(policy.calibration == nil)

            let previousPolicy = CBv2FirstTokenDeadlineAdmission(deadline: policy.deadline,
                conservativePrefillTokensPerSecond: 5, conservativeDecodeTokensPerSecond: 10)
            let previous = try await engine.submit(
                .init(id: .init(900_001), promptTokens: prompt, maxTokens: 1),
                firstTokenDeadline: previousPolicy)
            guard case .deadlineUnreachable(.bounded(let oldWork, let oldDuration)) = previous else {
                Issue.record("the former half-rate policy must refuse this same request and deadline")
                await bridge.shutdown()
                return
            }
            #expect(oldWork.prefillTokens == 100 && oldWork.decodeTokens == 0)
            #expect(oldDuration == .seconds(20))
            #expect(engine.capacity().activeRequests == 0)

            let tooLateProfile = RequestProfileBuilder()
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                    requestId: "too-late", firstContentDeadline: .init(
                        relativeBudgetMilliseconds: 6_000, receivedAt: now.advanced(by: .seconds(-5))),
                    profile: tooLateProfile)
            }
            #expect(tooLateProfile.wireObject().deadlineDecision?.verdict == .deadlineUnreachable)
            #expect(tooLateProfile.wireObject().deadlineDecision?.projectedServiceUs == 10_000_000)
            #expect(await bridge._testPendingSubmissionCount() == 0)

            let expiredProfile = RequestProfileBuilder()
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                    requestId: "expired", firstContentDeadline: .init(
                        relativeBudgetMilliseconds: 0, receivedAt: now), profile: expiredProfile)
            }
            #expect(expiredProfile.wireObject().deadlineDecision?.verdict == .expiredBeforeSubmit)
            #expect(engine.capacity().activeRequests == 0)

            let profile = RequestProfileBuilder()
            let stream = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                requestId: "fits-observed-rate", firstContentDeadline: deadline, profile: profile)
            var errors: [String] = []
            for await event in stream {
                if case .error(let message) = event { errors.append(message) }
            }
            #expect(errors.isEmpty)
            #expect(profile.wireObject().deadlineDecision?.verdict == .accepted)
            #expect(profile.wireObject().deadlineDecision?.projectedServiceUs == 10_000_000)
            #expect(engine.capacity().activeRequests == 0)
            await bridge.shutdown()
        } catch {
            await bridge.shutdown()
            throw error
        }
    }

    @Test("missing or invalid observed rates retain their original admission behavior")
    func invalidRatesRemainUnavailable() async throws {
        let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "observed-rate-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce)
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 60_000)
        let invalid: [Double?] = [nil, 0, -1, .nan, .infinity]
        for rate in invalid {
            await bridge.setDeadlineRatesForTesting(prefill: rate, decode: 20)
            #expect(await bridge.firstTokenDeadlineAdmission(deadline: deadline, isMultimodal: false) == nil)
            await bridge.setDeadlineRatesForTesting(prefill: 10, decode: rate)
            let policy = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: deadline, isMultimodal: false))
            #expect(policy.conservativePrefillTokensPerSecond == 10)
            #expect(policy.conservativeDecodeTokensPerSecond == nil)
            #expect(policy.deadline == deadline.instant)
        }
        await bridge.shutdown()
    }
}

private extension EngineV2Bridge {
    func setDeadlineRatesForTesting(prefill: Double?, decode: Double?) {
        isolatedPrefillTpsEwma = prefill ?? 0
        isolatedPrefillEwmaInitialized = prefill != nil
        observedDecodeTpsEwma = decode ?? 0
        ewmaInitialized = decode != nil
    }
}

/// Tiny deterministic tensors exercise the real scheduler and deadline verdict
/// without model weights or performance measurements.
private final class ObservedRateDeadlineModel: CBv2SteppableModel {
    let kinds = [CBv2LayerKind(attention: .full, headDim: 1, kvHeads: 1, queryHeads: 1)]

    func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
        let batch = tokens.dim(0), length = tokens.dim(1)
        let kv = MLXArray.ones([batch, 1, length, 1], dtype: .float32)
        for cache in caches {
            _ = cache.updateAndAttend(queries: kv, keys: kv, values: kv, scale: 1, sinks: nil)
        }
        return broadcast(MLXArray([Float(0), 1]).reshaped([1, 1, 2]), to: [batch, length, 2])
    }
}
