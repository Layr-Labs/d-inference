import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Admission rate inputs with synthetic observations and a scripted engine.
/// No model, GPU or real throughput is involved.
@Suite("Deadline admission rate estimators", .serialized)
struct AdmissionRateEstimatorTests {
    private typealias Policy = IsolatedPrefillAdmissionRate

    private func bridge(fixes: Bool, nominalPosture: Bool = true) -> (EngineV2Bridge, PrefillScriptEngine) {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, calibrationPosturePermitsWork: { nominalPosture },
            admissionFixes: fixes)
        return (bridge, engine)
    }

    private func observation(_ phase: String, tps: Double, at: ContinuousClock.Instant,
        contended: Bool = false) -> EngineRateObservation {
        EngineRateObservation(phase: phase, tps: tps, prompt: 512, context: 512, cache: "cold",
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
            engineIdle: true, nominalPosture: true) == 233)
        #expect(Policy.resolve(observed: 233, anchor: nil, evidenceAge: ancient,
            engineIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 233, anchor: nil, evidenceAge: ancient,
            engineIdle: false, nominalPosture: true) == 233)
        // The same expiry applies with an anchor: a calibration cell slowed by
        // another process must not keep an idle engine refusing either.
        #expect(Policy.resolve(observed: 40, anchor: 50, evidenceAge: expired,
            engineIdle: true, nominalPosture: true) == 50)
        #expect(Policy.resolve(observed: 40, anchor: 50, evidenceAge: ancient,
            engineIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: ancient,
            engineIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: ancient,
            engineIdle: false, nominalPosture: true) == 625)
        // Fresh evidence is trusted down to one eighth of the anchor.
        #expect(Policy.resolve(observed: 3_000, anchor: 5_000, evidenceAge: fresh,
            engineIdle: true, nominalPosture: true) == 3_000)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: fresh,
            engineIdle: true, nominalPosture: true) == 625)
        // Expired on an idle engine at nominal posture: never below the anchor.
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: expired,
            engineIdle: true, nominalPosture: true) == 5_000)
        #expect(Policy.resolve(observed: 7_000, anchor: 5_000, evidenceAge: expired,
            engineIdle: true, nominalPosture: true) == 7_000)
        // Busy or off-nominal engines keep only the floor until the long expiry.
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: expired,
            engineIdle: false, nominalPosture: true) == 625)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: expired,
            engineIdle: true, nominalPosture: false) == 625)
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: ancient,
            engineIdle: true, nominalPosture: false) == nil)
        // Undated or invalid inputs.
        #expect(Policy.resolve(observed: 233, anchor: 5_000, evidenceAge: nil,
            engineIdle: true, nominalPosture: true) == 625)
        #expect(Policy.resolve(observed: .nan, anchor: nil, evidenceAge: fresh,
            engineIdle: true, nominalPosture: true) == nil)
        #expect(Policy.resolve(observed: 400, anchor: .infinity, evidenceAge: expired,
            engineIdle: true, nominalPosture: true) == 400)
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
        #expect(DeadlineAdmissionFixes.decodeRateShape(shape, enabled: true, calibrated: false) == shape)
        #expect(DeadlineAdmissionFixes.decodeRateShape(shape, enabled: true, calibrated: true) == nil)
        #expect(DeadlineAdmissionFixes.decodeRateShape(shape, enabled: false, calibrated: false) == nil)
        #expect(DeadlineAdmissionFixes.decodeRateShape(shape, enabled: false, calibrated: true) == nil)
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
        #expect(await bridge.observedDecodeShapeEwma == .init(batchRows: 1))
        await bridge.shutdown()
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
        #expect(await bridge.observedDecodeShapeEwma == .init(batchRows: 4, tokensPerStep: 3, stepWidth: 4))
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
        #expect(await bridge.observedDecodeShapeEwma == .init(batchRows: 1))
        #expect(await bridge.observedDecodeTpsEwma == 120)
        await bridge.shutdown()
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
}

private extension EngineV2Bridge {
    func insertPendingSubmissionForTesting(_ id: String) { pendingSubmissionIDs.insert(id) }
    func removePendingSubmissionForTesting(_ id: String) { pendingSubmissionIDs.remove(id) }
}
