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

    private func installCalibrationSlot(_ fixture: ServeLoopFixture, gate: RecoveryStepGate,
        afterSelfTest: Bool = false, postureAllows: Bool = true) async throws -> EngineV2Bridge {
        let tokenizer = ModelCalibrationTokenizer()
        let selection = ModelCalibrationSessionGate(gate: gate, requestNumber: afterSelfTest ? 2 : 1)
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 4, shutdownGraceSeconds: 0,
            reservationForRequest: { _ in 1_024 }, makeSession: { request, cancellation in
                ModelCalibrationSession(request: request, cancellation: cancellation, gate: selection.next())
            })
        let bridge = await EngineV2Bridge(engine: engine, modelId: ServeLoopFixture.modelId,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], kvBytesPerToken: 1,
            kvBudget: fixture.loop.kvBudget, calibrationPosturePermitsWork: { postureAllows })
        _ = await fixture.runtime.unregister(modelId: ServeLoopFixture.modelId)
        await fixture.runtime.register(modelId: ServeLoopFixture.modelId, bridge: bridge)
        await fixture.loop.installModelSlotForTesting(modelId: ServeLoopFixture.modelId,
            container: cancelledPrefixContainer(tokenizer: CancelledPrefixTokenizer(prompt: [1, 2, 3])),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge)
        return bridge
    }
}

private extension EngineV2Bridge {
    func hasScheduledCalibration() -> Bool { modelCalibration.task != nil || modelCalibration.bootstrapCompleted }
}
#endif
