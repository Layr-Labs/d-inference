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
        // The throwing path refuses before any stream exists (a local 503).
        do {
            _ = try await otherBridge.submitTokenized(promptTokens: [1, 2], request: request,
                requestId: "other-throwing", firstContentDeadline: .init(relativeBudgetMilliseconds: 60_000))
            Issue.record("a full Mac must refuse before any stream exists")
        } catch MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(let message) {
            #expect(message == EngineV2Bridge.serviceAllowanceExhausted)
        }
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
        nativeMediaLearnedRequestIDs.insert(id)
        nextNativeMediaBootstrapAt = .now + .seconds(120)
    }
}

/// A row whose client went away keeps its serving slot until the engine drops
/// it at its next step and its pump releases it. Mac B's GPQA run (Muse
/// Glimmer, 8 rows) saw a capacity 503 twice right after a client closed a
/// stream, each served on retry: the next request asked for the slot the
/// cancelled row was still giving back.
@Suite("A cancelled row's slot goes to the next admission")
struct CancelledRowAdmissionTests {
    private static let model = "cancelled-row-model"
    private let request = ChatCompletionRequest(model: Self.model, messages: [], max_tokens: 1)

    /// Every whole-Mac slot but one is held, so the bridge's first row fills the Mac.
    private func nearlyFullMac() -> (GlobalKVCacheBudget, Int) {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let width = ServingPerformanceProfiles.legacyWholeMacConcurrency
        for slot in 0..<(width - 1) {
            _ = budget.serviceBudget.acquire(ownerID: "busy-\(slot)", concurrency: width)
        }
        return (budget, width)
    }

    private func bridge(_ engine: StepBoundaryCancelEngine, _ budget: GlobalKVCacheBudget) -> EngineV2Bridge {
        EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [], defaultMaxTokens: 64, maxConcurrentRequests: 8, kvBytesPerToken: 4_000, kvBudget: budget)
    }

    private func errors(in stream: AsyncStream<GenerationEvent>) async -> [String] {
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        return errors
    }

    @Test("on a full Mac, work that arrives while a cancelled row retires is admitted at its release, not refused",
          .timeLimit(.minutes(1)))
    func admittedAtRelease() async throws {
        let (budget, width) = nearlyFullMac()
        let engine = StepBoundaryCancelEngine(step: .milliseconds(100))
        let bridge = bridge(engine, budget)
        let left = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "left")
        #expect(engine.submitted.count == 1)
        #expect(budget.serviceBudget.count == width)
        // Its client went away: the cancel reaches the bridge at once; the engine drops the row a step later.
        await bridge.cancel(requestId: "left")
        let started = ContinuousClock.now
        let next = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "next")
        #expect(engine.submitted.count == 2, "refused the slot the cancelled row was giving back")
        #expect(started.duration(to: .now) < CancelledRowAdmissionWait.bound)
        #expect(budget.serviceBudget.count == width)
        #expect(await errors(in: left) == ["request cancelled"])
        engine.finishAll()
        #expect(await errors(in: next).isEmpty)
        await bridge.shutdown()
    }

    @Test("with no cancelled row a full Mac refuses at once, as before; so does the switch off",
          .timeLimit(.minutes(1)))
    func refusedAtOnceOtherwise() async throws {
        let (budget, _) = nearlyFullMac()
        let engine = StepBoundaryCancelEngine(step: .milliseconds(100))
        let bridge = bridge(engine, budget)
        let held = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "held")
        let started = ContinuousClock.now
        let refused = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "refused")
        #expect(await errors(in: refused) == [EngineV2Bridge.serviceAllowanceExhausted])
        #expect(started.duration(to: .now) < .milliseconds(500))
        // Off: the cancelled row's slot is not waited for.
        await bridge.setWaitsForCancelledRowsForTest(false)
        await bridge.cancel(requestId: "held")
        let off = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "off")
        #expect(await errors(in: off) == [EngineV2Bridge.serviceAllowanceExhausted])
        #expect(await errors(in: held) == ["request cancelled"])
        #expect(engine.submitted.count == 1)
        await bridge.shutdown()
        let key = CancelledRowAdmissionWait.environmentKey
        #expect(CancelledRowAdmissionWait.enabled(environment: [:]))
        #expect(CancelledRowAdmissionWait.enabled(environment: [key: "1"]))
        for off in ["0", "off", "FALSE", " false "] {
            #expect(!CancelledRowAdmissionWait.enabled(environment: [key: off]), "\(off)")
        }
        // The switch reaches the launchd daemon.
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
    }

    @Test("a cancelled row that never retires: the wait ends at its bound and the request is refused",
          .timeLimit(.minutes(1)))
    func wedgedRowRefusedAtTheBound() async throws {
        let (budget, _) = nearlyFullMac()
        let engine = StepBoundaryCancelEngine(step: nil)
        let bridge = bridge(engine, budget)
        let wedged = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "wedged")
        await bridge.cancel(requestId: "wedged")
        let started = ContinuousClock.now
        let refused = await bridge.submitTokenized(promptTokens: [1, 2], request: request, requestId: "refused")
        let waited = started.duration(to: .now)
        #expect(await errors(in: refused) == [EngineV2Bridge.serviceAllowanceExhausted])
        #expect(waited >= CancelledRowAdmissionWait.bound)
        #expect(waited < CancelledRowAdmissionWait.bound + .seconds(1))
        #expect(engine.submitted.count == 1)
        engine.finishAll()
        _ = await errors(in: wedged)
        await bridge.shutdown()
    }
}

/// Drops a cancelled row at its next step, as `EngineLoopV2.processCancellations`
/// does: the cancelled terminal comes `step` after the cancel, or never.
private final class StepBoundaryCancelEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var ids: [CBv2RequestID] = []
    private let step: Duration?

    init(step: Duration?) { self.step = step }

    var submitted: [CBv2RequestID] { lock.withLock { ids } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            streams[request.id] = continuation
            ids.append(request.id)
        }
        return stream
    }

    func finish(_ id: CBv2RequestID, _ reason: CBv2FinishReason) {
        guard let continuation = lock.withLock({ streams.removeValue(forKey: id) }) else { return }
        continuation.yield(.finished(reason: reason, usage: .init(promptTokens: 2, completionTokens: 0)))
        continuation.finish()
    }

    func finishAll() {
        for id in lock.withLock({ Array(streams.keys) }) { finish(id, .stop) }
    }

    func cancel(_ id: CBv2RequestID) {
        guard let step else { return }
        Task { [weak self] in
            try? await Task.sleep(for: step)
            self?.finish(id, .cancelled)
        }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async { finishAll() }
}

extension EngineV2Bridge {
    func setWaitsForCancelledRowsForTest(_ value: Bool) { waitsForCancelledRows = value }
}
