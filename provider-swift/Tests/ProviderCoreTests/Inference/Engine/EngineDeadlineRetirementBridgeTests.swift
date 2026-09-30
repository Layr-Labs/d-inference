import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Deadline admission retains whole-Mac service ownership")
struct EngineDeadlineRetirementBridgeTests {
    private func errors(in stream: AsyncStream<GenerationEvent>) async -> [String] {
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        return errors
    }

    @Test(arguments: [false, true])
    func admittedTerminalCannotAdmitAnotherModelBeforeRetirement(cancelled: Bool) async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let engine = PrefillScriptEngine(), otherEngine = PrefillScriptEngine()
        func makeBridge(_ engine: PrefillScriptEngine, model: String) -> EngineV2Bridge {
            EngineV2Bridge(engine: engine, modelId: model,
                tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
                prefillDeadlineMode: .enforce, kvBytesPerToken: 4_000, kvBudget: budget)
        }
        let bridge = makeBridge(engine, model: "deadline-owner")
        let otherBridge = makeBridge(otherEngine, model: "other-model")
        let activity = EngineMeasurementActivity()
        await bridge.setMeasurementActivity(activity)
        await otherBridge.setMeasurementActivity(activity)
        // The test targets retirement ownership; seed a numeric isolated rate
        // so the real bridge takes its atomic deadline-admission branch.
        await bridge.updatePrefillTpsEwma(2_000, isolated: true)
        let gate = PrefillRetirementGate()
        defer { gate.release() }
        engine.setRetirement(gate.retirement)

        let limit = ServingPerformanceProfiles.legacyWholeMacConcurrency
        for index in 0..<(limit - 1) {
            #expect(budget.serviceBudget.acquire(ownerID: "occupied-\(index)", concurrency: limit))
        }
        defer {
            for index in 0..<(limit - 1) { budget.serviceBudget.release(ownerID: "occupied-\(index)") }
        }
        let request = ChatCompletionRequest(model: "deadline-owner", messages: [], max_tokens: 1)
        let reservationID = UUID().uuidString.lowercased()
        let releases = ServiceReleaseRecorder()
        let lifetime = try #require(ServiceReservationLifetime(id: reservationID, onReleased: releases.record))
        let stream = try await bridge.submitTokenized(promptTokens: [1, 2], request: request,
            requestId: "held", firstContentDeadline: .init(relativeBudgetMilliseconds: 60_000),
            serviceReservationID: reservationID, serviceReservation: lifetime)
        await bridge.markNativeBootstrapOwnerForRetirementTest("held")
        #expect(engine.deadlineAdmissions.count == 1)
        let continuation = try #require(engine.continuations.last)
        continuation.yield(.finished(reason: cancelled ? .cancelled : .stop,
            usage: .init(promptTokens: 2, completionTokens: 0)))
        continuation.finish()
        let terminalErrors = await errors(in: stream)
        #expect(terminalErrors == (cancelled ? ["request cancelled"] : []))
        lifetime.finishPipeline()
        #expect(releases.ids.isEmpty, "a client terminal cannot acknowledge device retirement")

        #expect(budget.serviceBudget.count == limit)
        #expect(budget.serviceBudget.snapshot().reservations == [
            .init(id: reservationID, usedFraction: 1.0 / Double(limit))])
        #expect(abs(budget.serviceBudget.usedFraction - 1) < 1e-12)
        #expect(await budget.outstandingReservedBytes() > 0)
        // Generic bridges remove the active row at terminal; retirement lives
        // in the pending identity and pump, independently from slot counts.
        #expect(await bridge.activeRequestCount() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 1)
        #expect(await bridge._testLivePumpCount() == 1)
        #expect(await bridge.nativeMediaBootstrapRequestID == "held")
        #expect(await bridge.nextNativeMediaBootstrapAt != nil)
        let overlapping = EnginePrefillReceipt(activity: activity, model: "other-model")
        #expect(overlapping.overlap.contended)
        #expect(overlapping.overlap.otherModel)
        overlapping.end()
        let duplicate = try await bridge.submitTokenized(promptTokens: [1, 2], request: request,
            requestId: "held", firstContentDeadline: .init(relativeBudgetMilliseconds: 60_000))
        #expect(await errors(in: duplicate) == ["token_budget_exhausted: duplicate request ID"])
        #expect(engine.deadlineAdmissions.count == 1)
        let rejected = await otherBridge.submitTokenized(promptTokens: [1, 2], request: request,
            requestId: "other")
        #expect(await errors(in: rejected) == ["token_budget_exhausted: whole-Mac service allowance exhausted"])
        #expect(otherEngine.continuations.isEmpty)

        gate.release()
        let until = ContinuousClock.now.advanced(by: .seconds(3))
        while await bridge._testLivePumpCount() != 0, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge.nativeMediaBootstrapRequestID == nil)
        #expect(await bridge.nextNativeMediaBootstrapAt == nil)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(budget.serviceBudget.count == limit - 1)
        let isolated = EnginePrefillReceipt(activity: activity, model: "other-model")
        #expect(!isolated.overlap.contended)
        isolated.end()
        #expect(budget.serviceBudget.snapshot().reservations.isEmpty)
        #expect(releases.ids == [reservationID])
        let retried = await otherBridge.submitTokenized(promptTokens: [1, 2], request: request,
            requestId: "other")
        let otherContinuation = try #require(otherEngine.continuations.last)
        otherContinuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 2, completionTokens: 0)))
        otherContinuation.finish()
        #expect(await errors(in: retried).isEmpty)
        #expect(budget.serviceBudget.count == limit - 1)
        await bridge.shutdown()
        await otherBridge.shutdown()
    }
}

extension EngineV2Bridge {
    func markNativeBootstrapOwnerForRetirementTest(_ id: String) {
        nativeMediaBootstrapRequestID = id
        nativeMediaBootstrapLearned = true
        nextNativeMediaBootstrapAt = .now + .seconds(120)
    }
}
