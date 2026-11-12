import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

#if DEBUG
@Suite("Provider loop calibration scheduling", .serialized)
struct ProviderLoopCalibrationTests {
    @Test("registration schedules calibration before the first capacity tick while preserving posture gates",
        arguments: [false, true])
    func calibrationScheduledBeforeRegistration(postureAllows: Bool) async throws {
        let fixture = try await ServeLoopFixture.make(heartbeatIntervalSecs: 3_600)
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let bridge = try await installCalibrationSlot(fixture, gate: gate, postureAllows: postureAllows)
        let run = fixture.start()
        _ = try await fixture.awaitRegistration()
        #expect(await bridge.hasScheduledCalibration() == postureAllows,
            "registration schedules an eligible engine without bypassing its posture guard")
        gate.release()
        #expect(await fixture.stop(run))
        await bridge.shutdown()
    }

    @Test("preload completion schedules calibration after self-test even if the registration gate timed out",
        arguments: [false, true])
    func calibrationScheduledAfterPreload(timedOut: Bool) async throws {
        let id = ServeLoopFixture.modelId
        let info = ModelInfo(id: id, modelType: "gemma4", parameters: nil,
            quantization: "4bit", sizeBytes: 1, estimatedMemoryGb: 0.01)
        let fixture = try await ServeLoopFixture.make(models: [info], backend: BackendSettings(
            preloadModels: [id], startupPreloadTimeoutSecs: 1, startupSelftest: true))
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let bridge = try await installCalibrationSlot(fixture, gate: gate, afterSelfTest: true)
        await fixture.loop.removeModelSlotForTesting(modelId: id)
        _ = await fixture.runtime.unregister(modelId: id)
        let load = AsyncStream<Void>.makeStream()
        await fixture.loop.setStartupPreloadLoadOverrideForTesting { _ in
            for await _ in load.stream { break }
            await fixture.runtime.register(modelId: id, bridge: bridge)
            await fixture.loop.installModelSlotForTesting(modelId: id,
                container: cancelledPrefixContainer(tokenizer: CancelledPrefixTokenizer(prompt: [1, 2, 3])),
                tokenizer: TokenizerHandle(ModelCalibrationTokenizer()), engineV2: bridge)
        }
        if !timedOut { load.continuation.yield(); load.continuation.finish() }
        let outcome = await fixture.loop.runStartupPreloadGateForTesting()
        #expect(outcome == (timedOut ? .timedOut : .warm))
        if timedOut { load.continuation.yield(); load.continuation.finish() }
        let until = ContinuousClock.now + .seconds(5)
        while await fixture.loop.startupPreloadTaskRunningForTesting(), ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await bridge.hasScheduledCalibration())
        gate.release()
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        await bridge.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("all resident slots calibrate serially without waiting for a capacity tick")
    func residentSlotsChainAfterRetirement() async throws {
        let fixture = try await ServeLoopFixture.make(heartbeatIntervalSecs: 3_600)
        let gates = (0..<3).map { _ in RecoveryStepGate() }
        defer { for gate in gates { gate.release() } }
        var bridges: [EngineV2Bridge] = []
        for (id, gate) in zip([ServeLoopFixture.modelId, "second-model", "third-model"], gates) {
            bridges.append(try await installCalibrationSlot(fixture, gate: gate, modelID: id))
        }
        await fixture.loop.refreshModelCalibration()
        var scheduled = 0
        for bridge in bridges { if await bridge.hasScheduledCalibration() { scheduled += 1 } }
        #expect(scheduled == 1, "the Mac runs only one calibration session at a time")
        for gate in gates { gate.release() }
        let until = ContinuousClock.now + .seconds(5)
        var completed = 0
        repeat {
            completed = 0
            for bridge in bridges { if await bridge.completedCalibration() { completed += 1 } }
            if completed < bridges.count { try await Task.sleep(for: .milliseconds(1)) }
        } while completed < bridges.count && ContinuousClock.now < until
        #expect(completed == 3, "session retirement schedules the remaining resident engines")
        for bridge in bridges { await bridge.shutdown() }
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("foreground admission and draining prevent a retirement callback from starting another slot",
        arguments: [false, true])
    func cancelledChainDoesNotStartSuccessor(draining: Bool) async throws {
        let fixture = try await ServeLoopFixture.make()
        let gates = (0..<2).map { _ in RecoveryStepGate() }
        defer { for gate in gates { gate.release() } }
        let bridges = [
            try await installCalibrationSlot(fixture, gate: gates[0]),
            try await installCalibrationSlot(fixture, gate: gates[1], modelID: "second-model"),
        ]
        await fixture.loop.refreshModelCalibration()
        let firstTask = await bridges[0].scheduledCalibrationTask()
        let secondTask = await bridges[1].scheduledCalibrationTask()
        let running = try #require(firstTask ?? secondTask)
        let successor = firstTask == nil ? bridges[0] : bridges[1]
        var foreground: Task<IdleCalibrationForegroundLease?, Never>?
        if draining {
            await fixture.loop.beginServingDrain(owner: .lifecycle)
        } else {
            let budget = await fixture.loop.kvBudget.serviceBudget
            foreground = Task { await budget.idleCalibration.admittedLease() }
            let until = ContinuousClock.now + .seconds(5)
            while !running.isCancelled && ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(running.isCancelled)
        }
        for gate in gates { gate.release() }
        let lease = await foreground?.value ?? nil
        await running.value
        #expect(!(await successor.hasScheduledCalibration()))
        lease?.finish()
        for bridge in bridges { await bridge.shutdown() }
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("successful load completion prioritizes its slot before waking parked inference")
    func loadWaiterObservesScheduledCalibration() async throws {
        let fixture = try await ServeLoopFixture.make()
        let gate = RecoveryStepGate()
        let olderGate = RecoveryStepGate()
        defer { gate.release(); olderGate.release() }
        let bridge = try await installCalibrationSlot(fixture, gate: gate)
        let older = try await installCalibrationSlot(fixture, gate: olderGate, modelID: "000-older-model")
        let scheduled = try await fixture.loop.completeLoadWithWaitingInference(bridge: bridge)
        #expect(scheduled)
        #expect(!(await older.hasScheduledCalibration()))
        gate.release()
        olderGate.release()
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        await bridge.shutdown()
        await older.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("the load transition stays closed while calibration ownership is handed off",
        arguments: [false, true])
    func loadTransitionGateRemainsClosedDuringHandoff(cancelLoadOwner: Bool) async throws {
        let fixture = try await ServeLoopFixture.make()
        let computeGate = RecoveryStepGate()
        let handoffGate = RecoveryStepGate()
        defer { computeGate.release(); handoffGate.release() }
        let bridge = try await installCalibrationSlot(fixture, gate: computeGate, postureProbe: {
            if !handoffGate.entered { handoffGate.block() }
            return true
        })
        let completion = Task { try await fixture.loop.completeLoadWithWaitingInference(bridge: bridge) }
        let until = ContinuousClock.now + .seconds(5)
        while !handoffGate.entered && ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(handoffGate.entered)
        let (loading, modelWaiters, gateWaiters) = await fixture.loop.calibrationHandoffState()
        #expect(loading)
        #expect(modelWaiters == 1 && gateWaiters == 1)
        if cancelLoadOwner { completion.cancel() }
        handoffGate.release()
        #expect(try await completion.value)
        #expect(await fixture.loop.hasPublishedCalibrationSlot())
        let (stillLoading, remainingModelWaiters, remainingGateWaiters) = await fixture.loop.calibrationHandoffState()
        #expect(!stillLoading && remainingModelWaiters == 0 && remainingGateWaiters == 0)
        computeGate.release()
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        await bridge.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("a request behind a calibration probe whose engine stopped stepping ends when it is cancelled")
    func cancelledRequestStopsWaitingForAStuckProbe() async throws {
        let fixture = try await ServeLoopFixture.make(heartbeatIntervalSecs: 3_600)
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let bridge = try await installCalibrationSlot(fixture, gate: gate)
        await fixture.loop.refreshModelCalibration()
        let session = try #require(await bridge.scheduledCalibrationTask())
        let until = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.entered, "the probe's engine step is held, as on a Mac whose engine stopped stepping")

        let ended = CalibrationWaitFlag()
        let request = Task {
            defer { ended.set() }
            let stream = await bridge.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: ServeLoopFixture.modelId, messages: [], max_tokens: 4),
                requestId: "customer", cacheEnabled: false)
            for await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        let deadline = ContinuousClock.now + .seconds(5)
        while !ended.isSet && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let endedOnCancel = ended.isSet
        gate.release()
        await request.value
        await session.value
        #expect(endedOnCancel, "a cancelled request must end without waiting for the probe to retire")
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        await bridge.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("a request behind a probe that outlives the bound is refused for capacity, and the slot reads crashed until the probe retires")
    func requestIsRefusedWhenTheProbeOutlivesTheBound() async throws {
        let fixture = try await ServeLoopFixture.make(heartbeatIntervalSecs: 3_600)
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let bridge = try await installCalibrationSlot(fixture, gate: gate)
        let calibration = await fixture.loop.kvBudget.serviceBudget.idleCalibration
        calibration.retirementBound = .milliseconds(200)
        await fixture.loop.refreshModelCalibration()
        let session = try #require(await bridge.scheduledCalibrationTask())
        let until = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.entered)

        let ended = CalibrationWaitFlag()
        let refusal = CalibrationWaitMessage()
        let request = Task {
            defer { ended.set() }
            let stream = await bridge.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: ServeLoopFixture.modelId, messages: [], max_tokens: 4),
                requestId: "customer", cacheEnabled: false)
            for await event in stream { if case .error(let message) = event { refusal.record(message) } }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !ended.isSet && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let refusedInTime = ended.isSet
        let stateWhileStuck = await bridge.backendSlotCapacity().state
        gate.release()
        await request.value
        await session.value
        let stateAfterRetirement = await bridge.backendSlotCapacity().state
        #expect(refusedInTime, "a request must not wait past the bound for a probe that never retires")
        #expect(refusal.message?.hasPrefix("token_budget_exhausted") == true,
            "the refusal is retriable capacity, so the coordinator reroutes it")
        #expect(stateWhileStuck == "crashed", "the coordinator must stop routing to a slot whose probe is stuck")
        #expect(stateAfterRetirement != "crashed", "the slot serves again once the probe retires")
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 5)
        await fixture.mock.shutdown()
        await fixture.bridge.shutdown()
        await bridge.shutdown()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("the overdue refusal reaches the coordinator as retriable capacity: 503 token_budget_exhausted")
    func overdueRefusalIsRetriableCapacity() {
        let error = MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
            EngineV2Bridge.idleCalibrationRetirementOverdue)
        // As the inference handler maps a stream-start failure.
        let failure = ProviderLoop.sanitizedInferenceFailure(
            from: error, phase: .streamStart, errorReason: classifyInferenceErrorReason(error))
        #expect(failure.code == .capacity, "the coordinator fails a capacity refusal over to another Mac")
        #expect(failure.statusCode == 503)
        #expect(failure.errorReason == .tokenBudgetExhausted)
    }

    private func installCalibrationSlot(_ fixture: ServeLoopFixture, gate: RecoveryStepGate,
        afterSelfTest: Bool = false, postureAllows: Bool = true,
        modelID: String = ServeLoopFixture.modelId,
        postureProbe: (@Sendable () -> Bool)? = nil) async throws -> EngineV2Bridge {
        let tokenizer = ModelCalibrationTokenizer()
        let selection = ModelCalibrationSessionGate(gate: gate, requestNumber: afterSelfTest ? 2 : 1)
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 4, shutdownGraceSeconds: 0,
            reservationForRequest: { _ in 1_024 }, makeSession: { request, cancellation in
                ModelCalibrationSession(request: request, cancellation: cancellation, gate: selection.next())
            })
        let bridge = await EngineV2Bridge(engine: engine, modelId: modelID,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], kvBytesPerToken: 1,
            kvBudget: fixture.loop.kvBudget, calibrationPosturePermitsWork: postureProbe ?? { postureAllows })
        _ = await fixture.runtime.unregister(modelId: modelID)
        await fixture.runtime.register(modelId: modelID, bridge: bridge)
        await fixture.loop.installModelSlotForTesting(modelId: modelID,
            container: cancelledPrefixContainer(tokenizer: CancelledPrefixTokenizer(prompt: [1, 2, 3])),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge)
        return bridge
    }
}

private final class CalibrationWaitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class CalibrationWaitMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    var message: String? { lock.withLock { first } }
    func record(_ message: String) { lock.withLock { if first == nil { first = message } } }
}

private extension EngineV2Bridge {
    func scheduledCalibrationTask() -> Task<Void, Never>? { modelCalibration.task }
    func completedCalibration() -> Bool { modelCalibration.bootstrapCompleted }
    func hasScheduledCalibration() -> Bool { modelCalibration.task != nil || modelCalibration.bootstrapCompleted }
}
private extension ProviderLoop {
    func hasPublishedCalibrationSlot() -> Bool { modelSlots[ServeLoopFixture.modelId] != nil }

    func calibrationHandoffState() -> (Bool, Int, Int) {
        (isLoadingAny, loadingWaiters[ServeLoopFixture.modelId]?.count ?? 0, loadGateWaiters.count)
    }

    func completeLoadWithWaitingInference(bridge: EngineV2Bridge) async throws -> Bool {
        let id = ServeLoopFixture.modelId
        modelsLoading.insert(id)
        isLoadingAny = true
        let activity = kvBudget.serviceBudget.beginUnboundedActivity()
        defer { activity.finish() }
        // A real deferred-prefetch actor hop is the suspension that allowed
        // resumed inference to overtake calibration in the old ordering.
        // This model is already resident, so the pre-check never downloads.
        prefetchCoordinator = makePrefetchCoordinator()
        outboundSend = SendHandle { _ in }
        reserveDeferredPrefetches.insert(id)
        let waiter = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                loadingWaiters[id, default: []].append(continuation)
            }
            return await bridge.hasScheduledCalibration()
        }
        let gateWaiter = Task {
            await withCheckedContinuation { loadGateWaiters.append($0) }
            return !isLoadingAny
        }
        while loadingWaiters[id]?.isEmpty != false || loadGateWaiters.isEmpty { await Task.yield() }
        try await finishModelLoad(modelID: id, deviceActivity: activity)
        let result = try await waiter.value
        let gateOpened = await gateWaiter.value
        await prefetchCoordinator?.shutdown(timeout: .seconds(5))
        prefetchCoordinator = nil
        return result && gateOpened
    }
}
#endif
