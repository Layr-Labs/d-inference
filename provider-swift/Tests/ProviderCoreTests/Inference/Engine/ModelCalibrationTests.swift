import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Automatic model calibration", .serialized)
struct ModelCalibrationTests {
    private func fixture(budget: GlobalKVCacheBudget? = nil, gate: RecoveryStepGate? = nil)
        throws -> (EngineV2Bridge, CBv2NativeBlockEngine, GlobalKVCacheBudget) {
        let tokenizer = ModelCalibrationTokenizer()
        let budget = budget ?? GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 4, shutdownGraceSeconds: 0,
            reservationForRequest: { _ in 1_024 }, makeSession: { request, cancellation in
                ModelCalibrationSession(request: request, cancellation: cancellation, gate: gate)
            })
        let bridge = EngineV2Bridge(engine: engine, modelId: "mimo-calibration-fixture",
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], maxConcurrentRequests: 4,
            kvBytesPerToken: 1, kvBudget: budget)
        return (bridge, engine, budget)
    }

    private func waitForEntry(_ gate: RecoveryStepGate) async throws {
        let until = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < until {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(gate.entered)
        if !gate.entered { throw CancellationError() }
    }

    @Test("startup measurements seed heartbeats without billing/generation totals or warmup samples")
    func bootstrapUsesActualEngineReceipts() async throws {
        let (bridge, engine, budget) = try fixture()
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        await bridge.waitForCalibrationTest()
        let snapshot = await bridge.backendSlotCapacity()
        let measurements = try #require(snapshot.performanceMeasurements)
        #expect(measurements.isolatedPrefill?.sampleCount == 2)
        #expect(measurements.decode?.sampleCount == 2)
        #expect(measurements.workloadBuckets.contains { $0.phase == "prefill" && $0.promptTokenBucket == 1_024 })
        #expect(measurements.workloadBuckets.allSatisfy { $0.concurrentRequests == 1 })
        #expect(measurements.deliveredDecode == nil && measurements.endToEnd == nil)
        #expect(await bridge.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false,
            now: .now + .seconds(3_600))), "ordinary native models bootstrap once per loaded engine")
        await bridge.shutdown()
    }

    @Test("MiMo calibration retains its wider bootstrap and later maintenance measurements")
    func continuousCalibrationKeepsWideEvidence() async throws {
        let (bridge, engine, budget) = try fixture()
        // Exercise the existing continuous plan under the same shared idle
        // owner, without fabricating a published MiMo native transaction.
        await bridge.runContinuousCalibrationTest(budget: budget)
        let first = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(first.workloadBuckets.contains { $0.promptTokenBucket == 4_096 })
        #expect(first.workloadBuckets.contains { ($0.concurrentRequests ?? 1) > 1 })
        let before = try #require(first.isolatedPrefill?.sampleCount)
        await bridge.runContinuousCalibrationTest(budget: budget)
        let second = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(second.isolatedPrefill?.sampleCount == before + 3)
        #expect(await bridge.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("legacy engines without native retirement never start background calibration")
    func legacyEngineIsExcluded() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "legacy-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [])
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("requests on another model cancel calibration and wait for its actual native retirement")
    func foregroundPreemptsAcrossModels() async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (calibration, engine, budget) = try fixture(gate: gate)
        #expect(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        await calibration.interruptModelCalibration(["calibration-already-retired"])
        #expect(!(await calibration.wasCalibrationInterruptedTest()))
        let (foreground, _, _) = try fixture(budget: budget)
        let observed = RecoveryActivityAttempt()
        let task = Task {
            let stream = await foreground.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: "other", messages: [], max_tokens: 8), requestId: "customer")
            for await event in stream {
                if case .error(let error) = event { Issue.record("foreground request failed: \(error)") }
            }
            observed.markStarted()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!observed.started)
        #expect(engine.capacity().activeRequests > 0 && budget.serviceBudget.count == 1)
        gate.release()
        await task.value
        #expect(observed.started)
        #expect(await calibration.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(await foreground.calibrationCountersTest() == [3, 1, 8, 1])
        await calibration.shutdown()
        await foreground.shutdown()
    }

    @Test("native model startup calibration respects active work and shutdown")
    func admissionAndLifecycleBounds() async throws {
        let (bridge, _, budget) = try fixture()
        #expect(budget.serviceBudget.acquire(ownerID: "busy", concurrency: 24))
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        budget.serviceBudget.release(ownerID: "busy")
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        await bridge.stopModelCalibration()
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("shutdown retains calibration's service charge until the native step completes")
    func shutdownWaitsForActualRetirement() async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (bridge, engine, budget) = try fixture(gate: gate)
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        let completed = RecoveryActivityAttempt()
        let shutdown = Task { await bridge.shutdown(); completed.markStarted() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!completed.started)
        #expect(engine.capacity().activeRequests > 0 && budget.serviceBudget.count == 1)
        gate.release()
        await shutdown.value
        #expect(completed.started && budget.serviceBudget.count == 0)
        #expect(await bridge.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
    }

    @Test("calibration retirement preserves the original deadline and cancellation diagnostics", arguments: [false, true])
    func foregroundKeepsOriginalDeadline(cancel: Bool) async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (calibration, _, budget) = try fixture(gate: gate)
        #expect(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        let (foreground, engine, _) = try fixture(budget: budget)
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 10)
        let profile = RequestProfileBuilder()
        let request = Task { () -> DeadlineVerdict? in
            do {
                _ = try await foreground.submitTokenized(promptTokens: [1, 2, 3],
                    request: ChatCompletionRequest(model: "other", messages: [], max_tokens: 8),
                    requestId: "deadline-customer", firstContentDeadline: deadline, profile: profile)
                Issue.record("expired foreground request was admitted")
                return nil
            } catch is CancellationError {
                return .cancelled
            } catch is PreContentDeadlineFailure {
                return .expiredBeforeSubmit
            } catch {
                Issue.record("unexpected foreground failure: \(error)")
                return nil
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        if cancel { request.cancel() }
        gate.release()
        let expected: DeadlineVerdict = cancel ? .cancelled : .expiredBeforeSubmit
        #expect(await request.value == expected)
        #expect(profile.wireObject().deadlineDecision?.verdict == expected)
        #expect(profile.wireObject().deadlineDecision?.projectedServiceUs == nil)
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(await foreground.calibrationCountersTest() == [0, 0, 0, 0])
        await calibration.shutdown()
        await foreground.shutdown()
    }

    @Test("prompt sizing keeps complete role framing and actual prepared token bounds")
    func completeTemplates() async throws {
        let (bridge, _, _) = try fixture()
        for target in [128, 512, 4_096] {
            let tokens = try await bridge.modelCalibrationPrompt(targetTokens: target, variant: 1)
            #expect(tokens.count <= target && tokens.count > target / 2)
            #expect(tokens.first == 1 && tokens.last == 2)
        }
        await bridge.shutdown()
    }
}

private extension EngineV2Bridge {
    func runContinuousCalibrationTest(budget: GlobalKVCacheBudget) async {
        let task = budget.serviceBudget.idleCalibration.startIfIdle(isIdle: { budget.serviceBudget.isIdle }) {
            await self.runModelCalibration(continuous: true, requireNominalPosture: false)
        }
        #expect(task != nil)
        await task?.value
    }
    func waitForCalibrationTest() async { await modelCalibration.task?.value }
    func wasCalibrationInterruptedTest() -> Bool { modelCalibration.interrupted }
    func calibrationCountersTest() -> [Int64] {
        [prefillTokensTotal, prefillRequestsTotal, generatedTokensTotal, generationRequestsTotal]
    }
}
