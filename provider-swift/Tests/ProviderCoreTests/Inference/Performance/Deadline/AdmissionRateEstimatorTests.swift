import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Admission rate inputs with synthetic observations and a scripted engine.
/// No model, GPU or real throughput is involved.
@Suite("Deadline admission rate estimators", .serialized)
struct AdmissionRateEstimatorTests {
    private typealias Policy = IsolatedPrefillAdmissionRate

    private func bridge(fixes: Bool, nominalPosture: Bool = true,
        kvBudget: GlobalKVCacheBudget? = nil) -> (EngineV2Bridge, PrefillScriptEngine) {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, kvBudget: kvBudget,
            calibrationPosturePermitsWork: { nominalPosture }, admissionFixes: fixes)
        return (bridge, engine)
    }

    private func observation(_ phase: String, tps: Double, at: ContinuousClock.Instant,
        contended: Bool = false, prompt: Int = 512) -> EngineRateObservation {
        EngineRateObservation(phase: phase, tps: tps, prompt: prompt, context: prompt, cache: "cold",
            overlap: .init(contended: contended, peakRequests: contended ? 2 : 1), at: at,
            postureEpoch: nil, aggregate: true)
    }

    @Test("the kill switch is on by default and only an explicit off value disables it")
    func killSwitchParsing() {
        let key = DeadlineAdmissionFixes.environmentKey
        #expect(key == "DARKBLOOM_TTFT_ADMISSION_FIXES")
        #expect(DeadlineAdmissionFixes.resolve(environment: [:]))
        for value in ["1", "true", "on", "", "\n", "1\n"] {
            #expect(DeadlineAdmissionFixes.resolve(environment: [key: value]))
        }
        // Values from a file or deployment template can carry line endings.
        for value in ["0", "false", "OFF", " no ", "0\n", "off\r\n", "\tfalse\n", "\nno"] {
            #expect(!DeadlineAdmissionFixes.resolve(environment: [key: value]))
        }
    }

    @Test("expired idle evidence returns to the calibrated anchor; fresh slow evidence keeps a floor")
    func isolatedRatePolicy() {
        let fresh = Duration.seconds(30), expired = Duration.seconds(300), ancient = Duration.seconds(3_600)
        // No anchor: unchanged until the stale-evidence expiry fails open on an idle engine.
        #expect(Policy.resolve(observed: 233, anchor: nil, evidenceAge: expired,
            macIdle: true, nominalPosture: true) == 233)
        #expect(Policy.resolve(observed: 233, anchor: nil, evidenceAge: ancient,
            macIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 233, anchor: nil, evidenceAge: ancient,
            macIdle: false, nominalPosture: true) == 233)
        // The same expiry applies with an anchor: a calibration cell slowed by
        // another process must not keep an idle engine refusing either.
        #expect(Policy.resolve(observed: 40, anchor: 50, evidenceAge: expired,
            macIdle: true, nominalPosture: true) == 50)
        #expect(Policy.resolve(observed: 40, anchor: 50, evidenceAge: ancient,
            macIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: ancient,
            macIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: ancient,
            macIdle: false, nominalPosture: true) == 625)
        // Fresh evidence is trusted down to one eighth of the anchor.
        #expect(Policy.resolve(observed: 3_000, anchor: 5_000, evidenceAge: fresh,
            macIdle: true, nominalPosture: true) == 3_000)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: fresh,
            macIdle: true, nominalPosture: true) == 625)
        // Expired on an idle engine at nominal posture: never below the anchor.
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: expired,
            macIdle: true, nominalPosture: true) == 5_000)
        #expect(Policy.resolve(observed: 7_000, anchor: 5_000, evidenceAge: expired,
            macIdle: true, nominalPosture: true) == 7_000)
        // Busy or off-nominal engines keep only the floor until the long expiry.
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: expired,
            macIdle: false, nominalPosture: true) == 625)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: expired,
            macIdle: true, nominalPosture: false) == 625)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: ancient,
            macIdle: true, nominalPosture: false) == nil)
        // Undated or invalid inputs.
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: nil,
            macIdle: true, nominalPosture: true) == 625)
        #expect(Policy.resolve(observed: .nan, anchor: nil, evidenceAge: fresh,
            macIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 400, anchor: .infinity, evidenceAge: expired,
            macIdle: true, nominalPosture: true) == 400)
    }

    @Test("a contended sample after an idle gap cannot lock an ordinary engine out")
    func poisonedIsolatedRateRecovers() async throws {
        let now = ContinuousClock.now
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 12_000)
        for fixes in [true, false] {
            let (bridge, _) = bridge(fixes: fixes)
            await bridge.applyRateObservation(observation("isolated_prefill", tps: 5_000,
                at: now - .seconds(900)), requestID: "calibration-cell", calibration: true)
            // Another process slowed this prefill, but nothing overlapped inside
            // the provider. After the evidence gap it replaces the estimate.
            await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
                at: now - .seconds(300)), requestID: "serving", calibration: false)
            // Published evidence is unchanged either way.
            #expect(await bridge._testIsolatedPrefillTps() == 50)
            let idle = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: deadline, isMultimodal: false))
            #expect(idle.conservativePrefillTokensPerSecond == (fixes ? 5_000 : 50))

            await bridge.insertPendingSubmissionForTesting("queued-elsewhere")
            let busy = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: deadline, isMultimodal: false))
            #expect(busy.conservativePrefillTokensPerSecond == (fixes ? 625 : 50))
            await bridge.removePendingSubmissionForTesting("queued-elsewhere")

            // The next real measurement after the gap is used as measured.
            await bridge.applyRateObservation(observation("isolated_prefill", tps: 1_000, at: now),
                requestID: "renewed", calibration: false)
            let renewed = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: deadline, isMultimodal: false))
            #expect(renewed.conservativePrefillTokensPerSecond == 1_000)
            await bridge.shutdown()
        }
    }

    @Test("a slow calibration anchor cannot lock an idle engine out once its evidence is stale")
    func slowAnchorFailsOpenWhenStale() async throws {
        let now = ContinuousClock.now
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 12_000)
        for fixes in [true, false] {
            let (bridge, _) = bridge(fixes: fixes)
            // Startup calibration itself ran while another process held the GPU.
            await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
                at: now - .seconds(3_600)), requestID: "calibration-cell", calibration: true)
            let idle = await bridge.firstTokenDeadlineAdmission(deadline: deadline, isMultimodal: false)
            // Fixed: projection is skipped, as after a restart; the next request measures afresh.
            #expect(idle?.conservativePrefillTokensPerSecond == (fixes ? nil : 50))
            #expect((idle == nil) == fixes)
            await bridge.shutdown()
        }
    }

    @Test("a reviewed calibration keeps the per-row decode charge as its only fallback")
    func calibratedPolicyKeepsPerRowDecode() {
        let shape = CBv2DecodeRateShape(batchRows: 3, tokensPerStep: 2, stepWidth: 4)
        var step = MeasuredDecodeStep()
        step.observe(tokensPerSecond: 40, shape: shape, weight: 0.3, restart: true)
        func charge(enabled: Bool, calibrated: Bool) -> (Double?, CBv2DecodeRateShape?) {
            let result = DeadlineAdmissionFixes.decodeCharge(perRequestRate: 35, measuredStep: step,
                enabled: enabled, calibrated: calibrated)
            return (result.rate, result.shape)
        }
        #expect(charge(enabled: true, calibrated: false) == (40, shape))
        #expect(charge(enabled: true, calibrated: true) == (35, nil))
        #expect(charge(enabled: false, calibrated: false) == (35, nil))
        #expect(charge(enabled: false, calibrated: true) == (35, nil))
        // No decode evidence yet: no rate, whichever charge applies.
        let unmeasured = DeadlineAdmissionFixes.decodeCharge(perRequestRate: nil,
            measuredStep: MeasuredDecodeStep(), enabled: true, calibrated: false)
        #expect(unmeasured.rate == nil && unmeasured.shape == .init(batchRows: 1))
    }

    @Test("off-nominal posture does not restore the nominal calibration anchor")
    func anchorNeedsNominalPosture() async throws {
        let (bridge, _) = bridge(fixes: true, nominalPosture: false)
        let now = ContinuousClock.now
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 5_000,
            at: now - .seconds(900)), requestID: "calibration-cell", calibration: true)
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 2_000,
            at: now - .seconds(300)), requestID: "serving", calibration: false)
        let policy = try #require(await bridge.firstTokenDeadlineAdmission(
            deadline: .init(relativeBudgetMilliseconds: 12_000), isMultimodal: false))
        #expect(policy.conservativePrefillTokensPerSecond == 2_000)
        await bridge.shutdown()
    }

    @Test("the real submission path prices its own idle request at the anchor")
    func submissionPathTreatsItsOwnRequestAsIdle() async throws {
        let (bridge, engine) = bridge(fixes: true)
        engine.setDeadlineBehavior(.reject)
        let now = ContinuousClock.now
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 5_000,
            at: now - .seconds(900)), requestID: "calibration-cell", calibration: true)
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: now - .seconds(300)), requestID: "serving", calibration: false)
        await bridge.updateDecodeTpsEwma(40, shape: .init(batchRows: 2))
        let request = ChatCompletionRequest(model: "gemma-4-26b-qat-4bit", messages: [], max_tokens: 8)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 3_000),
                request: request, requestId: "after-idle",
                firstContentDeadline: .init(relativeBudgetMilliseconds: 12_000))
        }
        let policy = try #require(engine.deadlineAdmissions.last)
        #expect(policy.conservativePrefillTokensPerSecond == 5_000)
        #expect(policy.conservativeDecodeTokensPerSecond == 40)
        #expect(policy.decodeRateShape == .init(batchRows: 2))
        await bridge.shutdown()
    }

    @Test("admission carries the measured decode-step shape; the kill switch drops it")
    func decodeShapeReachesThePolicy() async throws {
        let alpha = 0.3
        func blend(_ new: Double, _ old: Double) -> Double { alpha * new + (1 - alpha) * old }
        for fixes in [true, false] {
            let (bridge, _) = bridge(fixes: fixes)
            await bridge.updatePrefillTpsEwma(5_000, isolated: true)
            await bridge.updateDecodeTpsEwma(30, shape: .init(batchRows: 4, tokensPerStep: 2, stepWidth: 4))
            await bridge.updateDecodeTpsEwma(30, shape: .init(batchRows: 1))
            let policy = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: .init(relativeBudgetMilliseconds: 12_000), isMultimodal: false))
            #expect(policy.conservativeDecodeTokensPerSecond == 30)
            let smoothed = CBv2DecodeRateShape(batchRows: blend(1, 4),
                tokensPerStep: blend(1, 2), stepWidth: blend(1, 4))
            #expect(policy.decodeRateShape == (fixes ? smoothed : nil))
            await bridge.shutdown()
        }
        // A malformed shape is smoothed as one plain row, never propagated.
        let (bridge, _) = bridge(fixes: true)
        await bridge.updateDecodeTpsEwma(30, shape: .init(batchRows: .nan, tokensPerStep: 0))
        #expect(await bridge.observedDecodeStep.shape == .init(batchRows: 1))
        await bridge.shutdown()
    }

    @Test("decode rate and step shape stay coupled across batch widths")
    func decodeRateAndShapeStayCoupled() async throws {
        let alpha = 0.3
        for fixes in [true, false] {
            let (bridge, _) = bridge(fixes: fixes)
            await bridge.updatePrefillTpsEwma(5_000, isolated: true)
            // Eight rows at 10 tok/s each (0.1 s steps), then one solo request
            // at 100 tok/s (0.01 s steps).
            await bridge.updateDecodeTpsEwma(10, shape: .init(batchRows: 8))
            await bridge.updateDecodeTpsEwma(100, shape: .init(batchRows: 1))
            // The published per-request rate is unchanged either way.
            #expect(await bridge.observedDecodeTpsEwma == alpha * 100 + (1 - alpha) * 10)
            let policy = try #require(await bridge.firstTokenDeadlineAdmission(
                deadline: .init(relativeBudgetMilliseconds: 12_000), isMultimodal: false))
            let rate = try #require(policy.conservativeDecodeTokensPerSecond)
            guard fixes else {
                #expect(rate == 37)
                #expect(policy.decodeRateShape == nil)
                await bridge.shutdown()
                continue
            }
            let shape = try #require(policy.decodeRateShape)
            #expect(shape == .init(batchRows: alpha * 1 + (1 - alpha) * 8))
            // One priced step is the smoothed measured step time.
            let stepSeconds = alpha * 0.01 + (1 - alpha) * 0.1
            #expect(abs(shape.tokensPerStep / rate - stepSeconds) < 1e-12)
            // An eight-row step is priced near its measured 0.1 s. Smoothing the
            // rate (37 tok/s) and rows separately priced it at about 0.037 s.
            let eightRowStep = shape.tokensPerStep / rate * max(1, 8 / shape.batchRows)
            #expect(eightRowStep > 0.098 && eightRowStep <= 0.1)
            // A solo step costs no less than the measured solo step.
            #expect(shape.tokensPerStep / rate >= 0.01)
            await bridge.shutdown()
        }
    }

    @Test("completed-request timing yields rows, confirmed tokens and width per decode step")
    func decodeShapeFromTiming() {
        var usage = CBv2Usage(promptTokens: 100, completionTokens: 10)
        var timing = CBv2RequestTiming()
        timing.decodeSteps = 9
        timing.batchRowsSum = 40
        usage.timing = timing
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false) == .init(batchRows: 4))
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: true) == .init(batchRows: 1))
        // Nine verify rounds drafted 27 tokens and confirmed 27 after the first.
        timing.mtpProposed = 27
        usage.timing = timing
        usage.completionTokens = 28
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false)
            == .init(batchRows: 4, tokensPerStep: 3, stepWidth: 4))
        // Degenerate counters clamp to one plain row and at most 64.
        timing.mtpProposed = 0
        timing.batchRowsSum = 0
        usage.timing = timing
        usage.completionTokens = 10
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false) == .init(batchRows: 1))
        timing.batchRowsSum = 10_000
        usage.timing = timing
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false).batchRows == 64)
        timing.decodeSteps = 0
        usage.timing = timing
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false) == .init(batchRows: 1))
        // The rate starts after the first-token step, so its rows are excluded
        // when known: an eight-row first step, then one solo decode step.
        timing.decodeSteps = 1
        timing.batchRowsSum = 9
        usage.timing = timing
        usage.completionTokens = 2
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false).batchRows == 4.5)
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false,
            firstTokenStepRows: 8) == .init(batchRows: 1))
        // Inconsistent first-step rows fall back to averaging over that step.
        #expect(EngineV2Bridge.engineDecodeShape(usage: usage, nativeBlock: false,
            firstTokenStepRows: 10).batchRows == 4.5)
    }

    @Test("a completed request's terminal timing reaches the measured decode shape")
    func completedRequestRecordsDecodeShape() async throws {
        let (bridge, engine) = bridge(fixes: true)
        let request = ChatCompletionRequest(model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: "user", content: "hi")], max_tokens: 32)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
            request: request, requestId: "measured-shape")
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.first)
        // Nine verify rounds at four rows confirmed 27 tokens after the first.
        var usage = CBv2Usage(promptTokens: 200, completionTokens: 28)
        var timing = CBv2RequestTiming()
        timing.firstTokenNanos = 1_000_000
        timing.lastTokenNanos = 101_000_000
        timing.lastTokenUptimeNanos = DispatchTime.now().uptimeNanoseconds
        timing.decodeSteps = 9
        timing.batchRowsSum = 40
        timing.mtpProposed = 27
        usage.timing = timing
        continuation.yield(.finished(reason: .stop, usage: usage))
        continuation.finish()
        await consumer.value
        #expect(await bridge.observedDecodeStep.shape == .init(batchRows: 4, tokensPerStep: 3, stepWidth: 4))
        await bridge.shutdown()
    }

    @Test("the first-token step's rows stay out of the decode-step shape")
    func firstTokenStepRowsExcluded() async throws {
        let (bridge, engine) = bridge(fixes: true)
        let request = ChatCompletionRequest(model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: "user", content: "hi")], max_tokens: 32)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 7, count: 200),
            request: request, requestId: "wide-first-step")
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.first)
        // The first token was confirmed in an eight-row step...
        var prefill = CBv2Usage(promptTokens: 200, completionTokens: 0)
        var prefillTiming = CBv2RequestTiming()
        prefillTiming.firstTokenNanos = 1_000_000
        prefillTiming.batchRowsSum = 8
        prefill.timing = prefillTiming
        engine.completePrefill(prefill)
        // ...and the nine decode steps the rate measures ran solo.
        var usage = CBv2Usage(promptTokens: 200, completionTokens: 10)
        var timing = CBv2RequestTiming()
        timing.firstTokenNanos = 1_000_000
        timing.lastTokenNanos = 91_000_000
        timing.lastTokenUptimeNanos = DispatchTime.now().uptimeNanoseconds
        timing.decodeSteps = 9
        timing.batchRowsSum = 17
        usage.timing = timing
        continuation.yield(.finished(reason: .stop, usage: usage))
        continuation.finish()
        await consumer.value
        // Averaging over the first-token step as well would report 1.7 rows.
        #expect(await bridge.observedDecodeStep.shape == .init(batchRows: 1))
        await bridge.shutdown()
    }

    @Test("a decode reset restarts the measured shape with the rate")
    func decodeShapeResetsWithRate() async {
        let (bridge, _) = bridge(fixes: true)
        let now = ContinuousClock.now
        var wide = observation("decode", tps: 20, at: now - .seconds(300))
        wide.decodeShape = .init(batchRows: 8, tokensPerStep: 2, stepWidth: 3)
        await bridge.applyRateObservation(wide, requestID: "busy-window", calibration: false)
        // A sample after the decode evidence expired starts both estimates over.
        var solo = observation("decode", tps: 120, at: now)
        solo.decodeShape = .init(batchRows: 1)
        await bridge.applyRateObservation(solo, requestID: "solo", calibration: false)
        #expect(await bridge.observedDecodeStep.shape == .init(batchRows: 1))
        #expect(await bridge.observedDecodeStep.tokensPerSecond == 120)
        #expect(await bridge.observedDecodeTpsEwma == 120)
        await bridge.shutdown()
    }

    @Test("the startup floor never loosens a fresh prompt-size bucket")
    func freshLongPromptBucketBelowFloor() async throws {
        let now = ContinuousClock.now
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 12_000)
        let (bridge, _) = bridge(fixes: true)
        // A 512-token calibration cell at 5,000 tok/s, then a legitimately slow
        // 32K-token prompt at 100 tok/s while both are fresh.
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 5_000,
            at: now - .seconds(30)), requestID: "calibration-cell", calibration: true)
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 100,
            at: now, prompt: 32_000), requestID: "long-prompt", calibration: false)
        let aggregate = 0.3 * 100 + 0.7 * 5_000
        func prefillRate(promptTokens: Int) async throws -> Double? {
            try #require(await bridge.firstTokenDeadlineAdmission(deadline: deadline,
                isMultimodal: false, promptTokens: promptTokens)).conservativePrefillTokensPerSecond
        }
        // The long bucket is priced as measured, not raised to 5,000 / 8.
        #expect(try await prefillRate(promptTokens: 32_000) == 100)
        #expect(try await prefillRate(promptTokens: 500) == aggregate)
        #expect(try await prefillRate(promptTokens: 0) == aggregate)
        await bridge.shutdown()
    }

    @Test("another model's request or device activity keeps the idle anchor and expiry off")
    func otherModelWorkKeepsAnchorOff() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30) })
        let services = budget.serviceBudget
        let (bridge, engine) = bridge(fixes: true, kvBudget: budget)
        engine.setDeadlineBehavior(.reject)
        let now = ContinuousClock.now
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 5_000,
            at: now - .seconds(900)), requestID: "calibration-cell", calibration: true)
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: now - .seconds(300)), requestID: "serving", calibration: false)
        let request = ChatCompletionRequest(model: "gemma-4-26b-qat-4bit", messages: [], max_tokens: 8)
        func submittedPrefillRate(_ id: String) async throws -> Double? {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 3_000),
                    request: request, requestId: id,
                    firstContentDeadline: .init(relativeBudgetMilliseconds: 12_000))
            }
            return try #require(engine.deadlineAdmissions.last).conservativePrefillTokensPerSecond
        }
        // The request's own whole-Mac lease is not other work.
        #expect(try await submittedPrefillRate("alone") == 5_000)
        // Another resident model holds the shared GPU: only the floor applies.
        #expect(services.acquire(ownerID: "other-model:busy", concurrency: 2))
        #expect(try await submittedPrefillRate("beside-other-model") == 625)
        services.release(ownerID: "other-model:busy")
        #expect(try await submittedPrefillRate("after-other-model") == 5_000)
        // A load, encoder preparation or cache transfer counts as well.
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 12_000)
        let activity = services.beginUnboundedActivity()
        #expect(try #require(await bridge.firstTokenDeadlineAdmission(deadline: deadline,
            isMultimodal: false, requestID: "during-load")).conservativePrefillTokensPerSecond == 625)
        activity.finish()
        await bridge.shutdown()

        // Another model's work also keeps 30-minute-old evidence priced
        // instead of skipping projection.
        let (stale, _) = self.bridge(fixes: true, kvBudget: budget)
        await stale.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: now - .seconds(3_600)), requestID: "calibration-cell", calibration: true)
        #expect(await stale.firstTokenDeadlineAdmission(deadline: deadline, isMultimodal: false) == nil)
        #expect(services.acquire(ownerID: "other-model:busy", concurrency: 2))
        #expect(await stale.firstTokenDeadlineAdmission(deadline: deadline, isMultimodal: false)?
            .conservativePrefillTokensPerSecond == 50)
        services.release(ownerID: "other-model:busy")
        await stale.shutdown()
    }

    @Test("a late older cold sample does not restart the combined prefill estimate")
    func lateColdSampleKeepsCombinedEstimate() async {
        let now = ContinuousClock.now
        for fixes in [true, false] {
            let (bridge, _) = bridge(fixes: fixes)
            await bridge.applyRateObservation(observation("isolated_prefill", tps: 2_000, at: now),
                requestID: "newer", calibration: false)
            await bridge.applyRateObservation(observation("contended_prefill", tps: 100,
                at: now - .seconds(121), contended: true), requestID: "older", calibration: false)
            let combined = await bridge.backendSlotCapacity().observedPrefillTps
            #expect(combined == (fixes ? 0.3 * 100 + 0.7 * 2_000 : 100))
            await bridge.shutdown()
        }
    }

    @Test("with the kill switch off, a late receipt still ages evidence from its own time")
    func killSwitchRestoresLastReceiptFreshness() {
        var measurements = EnginePerformanceMeasurements()
        measurements.keepsNewestObservationTime = false
        let at = ContinuousClock.now
        measurements.observe("isolated_prefill", tps: 2_000, prompt: 1_000, context: 1_000,
            cache: "cold", overlap: .init(), at: at)
        measurements.observe("isolated_prefill", tps: 100, prompt: 1_000, context: 1_000,
            cache: "cold", overlap: .init(), at: at - .seconds(121))
        #expect(measurements.snapshot(now: at + .seconds(1)).isolatedPrefill?.sampleAgeMs == 122_000)
        #expect(measurements.freshRate("isolated_prefill", now: at + .seconds(1)) == nil)
        #expect(measurements.observationAge("isolated_prefill", now: at + .seconds(1)) == .seconds(122))
        #expect(!measurements.coversObservation("isolated_prefill", at: at + .seconds(1)))
    }

    // MARK: - Refusal streak: a refused request measures nothing

    /// A recovery-sized prompt: the size `submit` sends unless told otherwise.
    private static let smallPrompt = 1_000

    /// A scripted-refusal bridge whose only isolated-prefill evidence is one
    /// slow sample `age` old, in the prompt-size bucket `submit` uses. With no
    /// calibration anchor, neither the idle anchor nor the short expiry applies.
    private func slowBridge(fixes: Bool = true, age: Duration = .seconds(300),
        kvBudget: GlobalKVCacheBudget? = nil) async -> (EngineV2Bridge, PrefillScriptEngine) {
        let (bridge, engine) = self.bridge(fixes: fixes, kvBudget: kvBudget)
        engine.setDeadlineBehavior(.reject)
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: ContinuousClock.now - age, prompt: Self.smallPrompt), requestID: "slow", calibration: false)
        return (bridge, engine)
    }

    private func submit(_ bridge: EngineV2Bridge, _ id: String, tokens: Int = smallPrompt,
        deadline: FirstContentDeadline = .init(relativeBudgetMilliseconds: 12_000),
        profile: RequestProfileBuilder? = nil) async throws -> AsyncStream<GenerationEvent> {
        try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: tokens),
            request: ChatCompletionRequest(model: "gemma-4-26b-qat-4bit", messages: [], max_tokens: 8),
            requestId: id, firstContentDeadline: deadline, profile: profile)
    }

    private func refuse(_ bridge: EngineV2Bridge, tokens: Int = smallPrompt, _ ids: String...) async {
        for id in ids {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await submit(bridge, id, tokens: tokens)
            }
        }
    }

    /// Ends the one ordinarily submitted request. A nil prefill time ends it
    /// before any prompt receipt, as a cancel during prefill does.
    private func finish(_ stream: AsyncStream<GenerationEvent>, on engine: PrefillScriptEngine,
        tokens: Int = smallPrompt, prefillMilliseconds: UInt64?) async throws {
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.last)
        if let prefillMilliseconds {
            engine.completeColdPrefill(milliseconds: prefillMilliseconds)
            continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        }
        continuation.yield(.finished(reason: prefillMilliseconds == nil ? .cancelled : .stop,
            usage: CBv2Usage(promptTokens: tokens, completionTokens: prefillMilliseconds == nil ? 0 : 1)))
        continuation.finish()
        await consumer.value
    }

    @Test("three refusals on stale evidence ask for one probe; no request is admitted unprojected")
    func refusalStreakAsksForProbe() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, "refused-1", "refused-2")
        #expect(!(await bridge.staleEvidenceProbeDue()))
        await refuse(bridge, "refused-3")
        #expect(engine.deadlineAdmissions.count == 3)
        #expect(engine.deadlineAdmissions.allSatisfy { $0.conservativePrefillTokensPerSecond == 50 })
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(await bridge.staleEvidenceProbeDue())
        // A started probe ends the streak and holds the next one to the interval.
        await bridge.recordEvidenceProbe()
        #expect(await bridge.deadlineRefusalStreak.refusals == 0)
        await refuse(bridge, "refused-4", "refused-5", "refused-6")
        #expect(!(await bridge.staleEvidenceProbeDue()))
        #expect(await bridge.staleEvidenceProbeDue(at: .now + DeadlineRefusalStreak.probeInterval))
        // The probe's cell, published as calibration, replaces the estimate
        // and the anchor, and the next request is priced from it.
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 1_000, at: .now),
            requestID: "calibration-probe", calibration: true)
        #expect(!(await bridge.staleEvidenceProbeDue()))
        await refuse(bridge, "after-probe")
        #expect(engine.deadlineAdmissions.last?.conservativePrefillTokensPerSecond == 1_000)
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("a probe that measures the Mac as slow anchors it there, and refusals at that rate ask for no more")
    func refusalStreakProbeConfirmsSlowMac() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, "refused-1", "refused-2", "refused-3")
        #expect(await bridge.staleEvidenceProbeDue())
        await bridge.recordEvidenceProbe()
        // 512 tokens at 50 tok/s, and that too is five minutes old now.
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: .now - .seconds(300)), requestID: "calibration-probe", calibration: true)
        await refuse(bridge, "slow-1", "slow-2", "slow-3", "slow-4", "slow-5")
        #expect(engine.deadlineAdmissions.suffix(5).allSatisfy { $0.conservativePrefillTokensPerSecond == 50 })
        #expect(await bridge.deadlineRefusalStreak.refusals == 0)
        #expect(!(await bridge.staleEvidenceProbeDue(at: .now + DeadlineRefusalStreak.probeInterval)))
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("long prompts refused on stale evidence count too: the probe never runs a customer prompt")
    func longPromptRefusalsAskForProbe() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, tokens: 30_000, "long-1", "long-2", "long-3")
        #expect(await bridge.staleEvidenceProbeDue())
        await expectRefused(bridge, engine, "long-4", tokens: 30_000)
        #expect(engine.deadlineAdmissions.count == 4)
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("a request whose absolute deadline has passed is refused whatever the refusal streak")
    func expiredDeadlineStillRefusedAfterStreak() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, "refused-1", "refused-2", "refused-3")
        let profile = RequestProfileBuilder()
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await submit(bridge, "expired",
                deadline: .init(relativeBudgetMilliseconds: 0, receivedAt: .now), profile: profile)
        }
        #expect(profile.wireObject().deadlineDecision?.verdict == .expiredBeforeSubmit)
        // Refused before any engine submission, projected or not.
        #expect(engine.deadlineAdmissions.count == 3)
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }

    @Test("fresh slow evidence keeps refusing however many requests it refuses")
    func freshSlowEstimateKeepsRefusing() async throws {
        let (bridge, engine) = await slowBridge(age: .zero)
        await refuse(bridge, "slow-1", "slow-2", "slow-3", "slow-4", "slow-5", "slow-6")
        #expect(engine.deadlineAdmissions.count == 6)
        #expect(engine.deadlineAdmissions.allSatisfy { $0.conservativePrefillTokensPerSecond == 50 })
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(await bridge.deadlineRefusalStreak.refusals == 0)
        await bridge.shutdown()
    }

    @Test("refusals a fresh prompt-size bucket prices do not count over a stale aggregate")
    func freshBucketKeepsRefusingAfterStreak() async throws {
        let (bridge, engine) = await slowBridge()
        // A wide calibration cell refreshes its prompt-size bucket and leaves
        // the aggregate, which stays expired, alone.
        await bridge.applyRateObservation(
            EngineRateObservation(phase: "isolated_prefill", tps: 50, prompt: Self.smallPrompt,
                context: Self.smallPrompt,
                cache: "cold", overlap: .init(contended: false, peakRequests: 2), at: .now,
                postureEpoch: nil, aggregate: false),
            requestID: "wide-cell", calibration: true)
        #expect(await bridge.isolatedPrefillEvidenceExpired())
        await refuse(bridge, "slow-1", "slow-2", "slow-3", "slow-4", "slow-5")
        #expect(engine.deadlineAdmissions.count == 5)
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(!(await bridge.staleEvidenceProbeDue()))
        await bridge.shutdown()
    }

    @Test("with the kill switch off, refusals never ask for a probe")
    func killSwitchKeepsRefusingAfterStreak() async throws {
        let (bridge, engine) = await slowBridge(fixes: false)
        await refuse(bridge, "refused-1", "refused-2", "refused-3", "refused-4", "refused-5")
        #expect(engine.deadlineAdmissions.count == 5)
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(!(await bridge.staleEvidenceProbeDue()))
        await bridge.shutdown()
    }

    @Test("refusals beside another model's work do not count toward the streak")
    func refusalsBesideOtherWorkAreNotCounted() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30) })
        let services = budget.serviceBudget
        let (bridge, engine) = await slowBridge(kvBudget: budget)
        // Queue or device contention, not the estimate, may explain these.
        #expect(services.acquire(ownerID: "other-model:busy", concurrency: 2))
        await refuse(bridge, "busy-1", "busy-2", "busy-3")
        services.release(ownerID: "other-model:busy")
        await refuse(bridge, "idle-1")
        #expect(engine.deadlineAdmissions.count == 4)
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(await bridge.deadlineRefusalStreak.refusals == 1)
        await bridge.shutdown()
    }

    @Test("a slow calibrated Mac keeps refusing long prompts however many it refuses")
    func slowAnchorKeepsRefusingLongPrompts() async throws {
        let (bridge, engine) = bridge(fixes: true)
        engine.setDeadlineBehavior(.reject)
        // The startup cell itself measured 50 tok/s and nothing ran since, so
        // the idle anchor prices every request at that rate.
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: ContinuousClock.now - .seconds(300)), requestID: "calibration-cell", calibration: true)
        #expect(await bridge.isolatedPrefillEvidenceExpired())
        await refuse(bridge, tokens: 30_000, "long-1", "long-2", "long-3", "long-4", "long-5")
        #expect(engine.deadlineAdmissions.count == 5)
        #expect(engine.deadlineAdmissions.allSatisfy { $0.conservativePrefillTokensPerSecond == 50 })
        #expect(engine.ordinarySubmissionCount == 0)
        #expect(!(await bridge.staleEvidenceProbeDue()))
        await bridge.shutdown()
    }

    @Test("a streak fills at three refusals, ends at any admission or probe, and a probe holds the next to its interval")
    func refusalStreakCounting() {
        typealias Streak = DeadlineRefusalStreak
        #expect(Streak.threshold == 3)
        #expect(Streak.probeInterval == EnginePerformanceMeasurements.freshness)
        #expect(Streak.minimumRemainingBudget == .seconds(5))
        let start = ContinuousClock.now
        var streak = Streak()
        streak.recordRefusal(tokensPerSecond: 50, promptTokens: 900)
        streak.recordRefusal(tokensPerSecond: 50, promptTokens: 900)
        #expect(!streak.permitsEvidenceProbe(at: start))
        streak.recordAdmission()
        for _ in 0..<2 { streak.recordRefusal(tokensPerSecond: 50, promptTokens: 900) }
        #expect(!streak.permitsEvidenceProbe(at: start))
        streak.recordRefusal(tokensPerSecond: 40, promptTokens: 30_000)
        #expect(streak.permitsEvidenceProbe(at: start))
        #expect(streak.lastRefusal?.tokensPerSecond == 40 && streak.lastRefusal?.promptTokens == 30_000)
        streak.recordProbe(at: start)
        #expect(streak.refusals == 0)
        for _ in 0..<5 { streak.recordRefusal(tokensPerSecond: 50, promptTokens: 900) }
        #expect(streak.refusals == 3)
        #expect(!streak.permitsEvidenceProbe(at: start + Streak.probeInterval - .seconds(1)))
        #expect(streak.permitsEvidenceProbe(at: start + Streak.probeInterval))
        // An admission in the interval ends the streak; the interval stays.
        streak.recordAdmission()
        #expect(!streak.permitsEvidenceProbe(at: start + Streak.probeInterval))
    }

    // MARK: - Only refusals that stale evidence explains count

    /// Expects an immediate refusal. An admitted request is recorded as an
    /// issue and ended, so shutdown never waits for it.
    private func expectRefused(_ bridge: EngineV2Bridge, _ engine: PrefillScriptEngine, _ id: String,
        tokens: Int = smallPrompt,
        deadline: FirstContentDeadline = .init(relativeBudgetMilliseconds: 12_000)) async {
        do {
            let stream = try await submit(bridge, id, tokens: tokens, deadline: deadline)
            Issue.record("\(id) was admitted")
            try? await finish(stream, on: engine, tokens: tokens, prefillMilliseconds: nil)
        } catch {
            #expect(error as? PreContentDeadlineFailure == .deadlineUnreachable, "\(id): \(error)")
        }
    }

    /// The bridge retires a request after its stream ends, on its own actor hop.
    private func waitForRetirement(_ bridge: EngineV2Bridge) async throws {
        let until = ContinuousClock.now + .seconds(5)
        while true {
            let active = await bridge._testActiveRequestIds()
            let pending = await bridge._testPendingSubmissionCount()
            if active.isEmpty && pending == 0 { return }
            try #require(ContinuousClock.now < until, "never retired: active \(active), pending \(pending)")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("a full streak keeps refusing from the stale estimate and never submits a request unprojected")
    func fullStreakNeverAdmitsUnprojected() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, "refused-1", "refused-2", "refused-3")
        #expect(await bridge.staleEvidenceProbeDue())
        await expectRefused(bridge, engine, "small")
        #expect(engine.deadlineAdmissions.count == 4)
        #expect(engine.deadlineAdmissions.allSatisfy { $0.conservativePrefillTokensPerSecond == 50 })
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("after a full streak a late retry is refused at once")
    func lateRetryRefusedAfterStreak() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, "refused-1", "refused-2", "refused-3")
        // 300 ms left: out of time on any Mac. Unprojected, it would run here
        // past its deadline and leave the coordinator no time for another Mac.
        await expectRefused(bridge, engine, "late-retry", tokens: 800,
            deadline: .init(relativeBudgetMilliseconds: 300))
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("refusals priced at a fresh rate do not count, so the aged estimate still prices the next request")
    func freshRefusalsDoNotFillTheStreak() async throws {
        let (bridge, engine) = bridge(fixes: true)
        engine.setDeadlineBehavior(.reject)
        // A correct rate measured 119 s ago: fresh while three long prompts are refused.
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 2_000,
            at: ContinuousClock.now - .seconds(119), prompt: Self.smallPrompt),
            requestID: "measured", calibration: false)
        for id in ["long-1", "long-2", "long-3"] {
            await expectRefused(bridge, engine, id, tokens: 60_000)
        }
        #expect(await bridge.deadlineRefusalStreak.refusals == 0)
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(await bridge.isolatedPrefillEvidenceExpired())
        await expectRefused(bridge, engine, "small", tokens: 800)
        #expect(engine.deadlineAdmissions.count == 4)
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("late retries do not count")
    func lateRetriesDoNotFillTheStreak() async throws {
        let (bridge, engine) = await slowBridge()
        for id in ["retry-1", "retry-2", "retry-3"] {
            await expectRefused(bridge, engine, id, deadline: .init(relativeBudgetMilliseconds: 3_000))
        }
        #expect(engine.deadlineAdmissions.count == 3)
        #expect(await bridge.deadlineRefusalStreak.refusals == 0)
        await bridge.shutdown()
    }

    @Test("refusals priced at the calibration anchor do not count")
    func anchoredRefusalsDoNotFillTheStreak() async throws {
        let (bridge, engine) = bridge(fixes: true)
        engine.setDeadlineBehavior(.reject)
        await bridge.applyRateObservation(observation("isolated_prefill", tps: 50,
            at: ContinuousClock.now - .seconds(300)), requestID: "calibration-cell", calibration: true)
        for id in ["long-1", "long-2", "long-3"] {
            await expectRefused(bridge, engine, id, tokens: 30_000)
        }
        #expect(engine.deadlineAdmissions.allSatisfy { $0.conservativePrefillTokensPerSecond == 50 })
        #expect(await bridge.deadlineRefusalStreak.refusals == 0)
        await bridge.shutdown()
    }

    @Test("a projected admission ends a partial streak")
    func projectedAdmissionEndsPartialStreak() async throws {
        let (bridge, engine) = await slowBridge()
        await refuse(bridge, "refused-1", "refused-2")
        #expect(await bridge.deadlineRefusalStreak.refusals == 2)
        engine.setDeadlineBehavior(.admit)
        let stream = try await submit(bridge, "projected")
        #expect(engine.deadlineAdmissions.count == 3)
        #expect(engine.ordinarySubmissionCount == 0)
        // Ended before its prompt completed: it measured nothing. A refusal
        // counts only on an idle Mac, so the next one waits for its retirement.
        try await finish(stream, on: engine, prefillMilliseconds: nil)
        try await waitForRetirement(bridge)
        #expect(await bridge.isolatedPrefillEvidenceExpired())
        engine.setDeadlineBehavior(.reject)
        await refuse(bridge, "refused-3")
        #expect(await bridge.deadlineRefusalStreak.refusals == 1)
        await bridge.shutdown()
    }
}

private extension EngineV2Bridge {
    func insertPendingSubmissionForTesting(_ id: String) { pendingSubmissionIDs.insert(id) }
    func removePendingSubmissionForTesting(_ id: String) { pendingSubmissionIDs.remove(id) }
}
