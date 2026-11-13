import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// GLM-5.3-Flash and MiMo V2.6 run native engines (`supportsPrefillRecoveryRetirement`).
/// Production shapes from 11-13 (`earnings/glm-deadline-evidence/prod`): idle GLM M5 Ultras
/// calibrate about 1,420 tok/s on their 512-token cells and prefill prompts above 4K tokens at
/// 1,378-2,031 tok/s, yet a 13-20-token prompt takes 0.1-1.3 s and records 9-140 tok/s. That
/// sample priced the Tau2 first turn (3,772 tokens, 12.6 s left) at 85 tok/s, 44 s, so the
/// idle Macs refused it. A scripted native block engine stands in for the native engines; the
/// real projection engine gives the verdict. No model weights or real throughput are involved.
@Suite("Native prefill evidence (GLM, MiMo)", .serialized)
struct NativePrefillEvidenceTests {
    private static let calibrated = 1_420.0
    private static let tau2Prompt = 3_772
    /// Milliseconds the Macs had left for the Tau2 first turns (TAU2-AUDIT t13, p50).
    private static let tau2RemainingMs: Int64 = 12_619

    private func nativeBridge(nominalPosture: Bool = true) throws -> (EngineV2Bridge, GlobalKVCacheBudget) {
        let engine = try CBv2NativeBlockEngine(tokenizer: PrefillStubTokenizer(), kvBytesCapacity: 1 << 20,
            shutdownGraceSeconds: 0, loopConfig: .init(stepTimeout: 60, watchdogInterval: 0.01),
            reservationForRequest: { _ in 1_024 }, makeSession: { request, cancellation in
                RecoverySession(tokens: request.promptTokens.count, cancellation: cancellation,
                    gate: nil, decodeGate: nil)
            })
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: "glm-5.3-flash",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, kvBytesPerToken: 1, kvBudget: budget,
            calibrationPosturePermitsWork: { nominalPosture })
        return (bridge, budget)
    }

    /// An ordinary (non-native) engine, as the other models run.
    private func ordinaryBridge() -> EngineV2Bridge {
        EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, calibrationPosturePermitsWork: { true })
    }

    private func cold(_ tps: Double, prompt: Int, at: ContinuousClock.Instant) -> EngineRateObservation {
        EngineRateObservation(phase: "isolated_prefill", tps: tps, prompt: prompt, context: prompt,
            cache: "cold", overlap: .init(), at: at, postureEpoch: nil, aggregate: true)
    }

    /// The startup (GLM) or maintenance (MiMo) calibration's measured 512-token cell.
    private func calibrate(_ bridge: EngineV2Bridge, _ tps: Double = calibrated, prompt: Int = 512,
        at: ContinuousClock.Instant) async {
        await bridge.applyRateObservation(cold(tps, prompt: prompt, at: at),
            requestID: "calibration-cell", calibration: true)
    }

    private func serve(_ bridge: EngineV2Bridge, _ tps: Double, prompt: Int, at: ContinuousClock.Instant) async {
        await bridge.applyRateObservation(cold(tps, prompt: prompt, at: at),
            requestID: "served-\(prompt)", calibration: false)
    }

    private func policy(_ bridge: EngineV2Bridge, prompt: Int,
        remainingMs: Int64 = tau2RemainingMs) async throws -> CBv2FirstTokenDeadlineAdmission {
        try #require(await bridge.firstTokenDeadlineAdmission(
            deadline: .init(relativeBudgetMilliseconds: remainingMs), isMultimodal: false,
            requestID: "priced", promptTokens: prompt))
    }

    private func prefillRate(_ bridge: EngineV2Bridge, prompt: Int) async throws -> Double {
        try #require(try await policy(bridge, prompt: prompt).conservativePrefillTokensPerSecond)
    }

    private func projectionEngine() -> EngineV2 {
        let model = DeadlineAdmissionFixtureModel()
        return EngineV2(model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 24)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            sampler: CBv2GreedySampler(), schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 4_096,
                prefillChunkSize: 4_096, maxConcurrentPartialPrefills: 1,
                maxWaiting: 4, enablePrefixCache: false))
    }

    @Test("a 13-token prompt's sample no longer prices GLM's 3,772-token Tau2 first turn, and the engine admits it")
    func tinyPromptCannotPriceTheTau2FirstTurn() async throws {
        let (bridge, _) = try nativeBridge()
        let now = ContinuousClock.now
        await calibrate(bridge, at: now - .seconds(600))
        await bridge.updateDecodeTpsEwma(60)
        // 13 tokens in about one second: the request's fixed cost, not a prefill rate.
        await serve(bridge, 13, prompt: 13, at: now - .seconds(5))
        let admission = try await policy(bridge, prompt: Self.tau2Prompt)
        let rate = try #require(admission.conservativePrefillTokensPerSecond)
        #expect(rate >= Self.calibrated)
        // The SDK projection that refused the run: 3,772 tokens at 13 tok/s is 290 s.
        let engine = projectionEngine()
        let result = try await engine.submit(.init(id: .init(7), promptTokens: Array(repeating: 1,
            count: Self.tau2Prompt), maxTokens: 1), firstTokenDeadline: admission)
        guard case .admitted(let events, .bounded(_, let projected), _, let retirement) = result else {
            await engine.shutdown()
            await bridge.shutdown()
            Issue.record("an idle native Mac must admit the Tau2 first turn: \(result)")
            return
        }
        #expect(projected < .seconds(3))
        for await _ in events {}
        await retirement.wait()
        await engine.shutdown()
        await bridge.shutdown()
    }

    @Test("a tiny prompt every minute cannot walk an idle GLM Mac's estimate down (production Mac 7)")
    func tinyPromptsEveryMinuteDoNotDecayTheEstimate() async throws {
        let (bridge, _) = try nativeBridge()
        let now = ContinuousClock.now
        await calibrate(bridge, at: now - .seconds(1_200))
        // A 60K-token prompt measured 2,000 tok/s fifteen minutes ago.
        await serve(bridge, 2_000, prompt: 60_653, at: now - .seconds(900))
        // Then a 10-token prompt at about 9 tok/s once a minute.
        for minute in (0..<12).reversed() {
            await serve(bridge, 9, prompt: 10, at: now - .seconds(60 * minute + 5))
        }
        // The slot's heartbeat telemetry follows the admission estimate.
        #expect(await bridge._testIsolatedPrefillTps() == 2_000)
        #expect(try await prefillRate(bridge, prompt: 23_466) == 2_000)
        #expect(try await prefillRate(bridge, prompt: Self.tau2Prompt) == 2_000)
        await bridge.shutdown()
    }

    @Test("a busy GLM Mac prices from its long-prompt evidence, not from a tiny prompt")
    func busyMacUsesLongPromptEvidence() async throws {
        let (bridge, budget) = try nativeBridge()
        let now = ContinuousClock.now
        await calibrate(bridge, at: now - .seconds(1_200))
        await serve(bridge, 1_900, prompt: 20_000, at: now - .seconds(600))
        #expect(budget.serviceBudget.acquire(ownerID: "another-model", concurrency: 4))
        await serve(bridge, 13, prompt: 13, at: now - .seconds(5))
        // Busy: no calibrated floor, but the tiny prompt does not count either.
        #expect(try await prefillRate(bridge, prompt: 23_466) == 1_900)
        budget.serviceBudget.release(ownerID: "another-model")
        await bridge.shutdown()
    }

    @Test("below 4K tokens the prompt-size bucket cannot undercut a native prompt with a short sample")
    func shortBucketDoesNotTightenNativePrompts() async throws {
        let (bridge, _) = try nativeBridge()
        let now = ContinuousClock.now
        await calibrate(bridge, at: now - .seconds(1_200))
        // A 540-token prompt took 4.5 s on an idle Mac that had just woken.
        await serve(bridge, 120, prompt: 540, at: now - .seconds(5))
        #expect(try await prefillRate(bridge, prompt: 1_000) == Self.calibrated)
        #expect(try await prefillRate(bridge, prompt: Self.tau2Prompt) == Self.calibrated)
        await bridge.shutdown()
    }

    @Test("MiMo: a tiny prompt between maintenance cells does not drag the 512-token rate down")
    func mimoMaintenanceRateHolds() async throws {
        let (bridge, _) = try nativeBridge()
        let now = ContinuousClock.now
        // MiMo's maintenance plan: 512, 4,096 and 512 prompt tokens.
        await calibrate(bridge, 450, at: now - .seconds(100))
        await calibrate(bridge, 600, prompt: 4_096, at: now - .seconds(90))
        await calibrate(bridge, 450, at: now - .seconds(80))
        // An 18-token prompt at 6 tok/s: today 0.3 of it pulls 450 down to 317 tok/s,
        // which refuses a 4,242-token turn with 12.7 s left (13.4 s projected).
        await serve(bridge, 6, prompt: 18, at: now - .seconds(5))
        let rate = try await prefillRate(bridge, prompt: 4_242)
        #expect(rate == 450)
        #expect(Double(4_242) / rate < 12.7)
        await bridge.shutdown()
    }

    @Test("fresh slow evidence from a long prompt still prices an idle native Mac")
    func freshLongPromptEvidenceIsTrusted() async throws {
        let (bridge, _) = try nativeBridge()
        let now = ContinuousClock.now
        await calibrate(bridge, at: now - .seconds(1_200))
        // Something else slowed this Mac: a 6,000-token prompt ran at 400 tok/s 30 s ago.
        await serve(bridge, 400, prompt: 6_000, at: now - .seconds(30))
        #expect(try await prefillRate(bridge, prompt: Self.tau2Prompt) == 400)
        #expect(try await prefillRate(bridge, prompt: 6_000) == 400)
        await bridge.shutdown()
    }

    @Test("ordinary engines keep today's estimator")
    func ordinaryEnginesUnchanged() async throws {
        let bridge = ordinaryBridge()
        let now = ContinuousClock.now
        await calibrate(bridge, at: now - .seconds(600))
        await serve(bridge, 13, prompt: 13, at: now - .seconds(5))
        // Fresh evidence keeps one eighth of the anchor (`IsolatedPrefillAdmissionRate`).
        #expect(await bridge._testIsolatedPrefillTps() == 13)
        #expect(try await prefillRate(bridge, prompt: Self.tau2Prompt) == Self.calibrated / 8)
        await bridge.shutdown()
    }
}
