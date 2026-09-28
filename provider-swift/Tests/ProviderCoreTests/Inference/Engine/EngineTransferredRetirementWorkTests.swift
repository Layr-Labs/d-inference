import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Commits a stream before returning atomic admission, allowing real confirmed
/// output to race with cancellation/deadline expiry at that return boundary.
private final class TransferredAdmissionEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var output: AsyncStream<CBv2Event>.Continuation?
    private var cancellations = 0
    let admission = PrefillRetirementGate()
    let retirement = PrefillRetirementGate()
    let throwAdmissionCancellation: Bool

    init(throwAdmissionCancellation: Bool) {
        self.throwAdmissionCancellation = throwAdmissionCancellation
    }

    var continuation: AsyncStream<CBv2Event>.Continuation? {
        lock.withLock { output }
    }

    var cancellationCount: Int { lock.withLock { cancellations } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        Issue.record("expected atomic deadline admission")
        return AsyncStream { $0.finish() }
    }

    func submit(
        _ request: CBv2Request,
        firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let admittedAt = ContinuousClock.now
        lock.withLock { output = continuation }
        await admission.wait()
        if throwAdmissionCancellation {
            throw CBv2FirstTokenAdmissionCancellation(
                stream: stream, retirement: retirement.retirement)
        }
        return .admitted(
            stream: stream,
            projectedWork: .bounded(
                work: .init(prefillTokens: request.promptTokens.count,
                    decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
                serviceDuration: .milliseconds(1)),
            admittedAt: admittedAt,
            retirement: retirement.retirement)
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { cancellations += 1 }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

@Suite("Transferred admission reconciles executed output work")
struct EngineTransferredRetirementWorkTests {
    enum Stop: CaseIterable, Sendable {
        case cancellation, deadline, admissionCancellation
    }

    @Test(arguments: Stop.allCases, [Optional(7), Optional(1), nil])
    func retiredWorkIsCountedWithoutClientUsage(
        stop: Stop, terminalCompletion: Int?
    ) async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let engine = TransferredAdmissionEngine(
            throwAdmissionCancellation: stop == .admissionCancellation)
        let bridge = EngineV2Bridge(engine: engine, modelId: "transferred-work",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, kvBytesPerToken: 4_000, kvBudget: budget)
        let activity = EngineMeasurementActivity()
        await bridge.setMeasurementActivity(activity)
        await bridge.updatePrefillTpsEwma(2_000, isolated: true)
        let usageSignal = EngineV2RequestUsageSignal()
        let deadline = FirstContentDeadline(
            relativeBudgetMilliseconds: stop == .deadline ? 500 : 60_000)
        let submission = Task {
            try await bridge.submitTokenized(promptTokens: [1, 2],
                request: .init(model: "transferred-work", messages: [], max_tokens: 10),
                requestId: "transferred", usageSignal: usageSignal,
                firstContentDeadline: deadline)
        }
        defer {
            engine.continuation?.finish()
            engine.admission.release()
            engine.retirement.release()
            submission.cancel()
        }
        let admissionLimit = ContinuousClock.now + .seconds(3)
        while engine.continuation == nil, ContinuousClock.now < admissionLimit {
            try await Task.sleep(for: .milliseconds(1))
        }
        let continuation = try #require(engine.continuation)
        continuation.yield(.delta(text: "unpublished output", tokens: [7, 8], logprobs: nil))
        switch stop {
        case .cancellation:
            await bridge.cancel(requestId: "transferred")
        case .deadline:
            try await ContinuousClock().sleep(until: deadline.instant + .milliseconds(1))
        case .admissionCancellation:
            submission.cancel()
        }
        engine.admission.release()

        // The caller gets only its existing pre-content failure. No client
        // event pump or billable terminal is installed for the admitted row.
        if stop == .deadline {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await submission.value
            }
        } else {
            await #expect(throws: CancellationError.self) {
                _ = try await submission.value
            }
        }
        #expect(engine.cancellationCount > 0)
        #expect(await bridge.activeRequestCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 1)
        #expect(await budget.outstandingReservedBytes() > 0)
        #expect(budget.serviceBudget.count == 1)
        #expect(await bridge.backendSlotCapacity().telemetry?.generationRequestsTotal == 0)
        // A new model's measurement must see the admitted row while its
        // retirement owner still holds device work, even without active state.
        let overlapping = EnginePrefillReceipt(activity: activity, model: "other-model")
        #expect(overlapping.overlap.contended)
        #expect(overlapping.overlap.otherModel)
        overlapping.end()

        if let terminalCompletion {
            continuation.yield(.finished(reason: .cancelled,
                usage: .init(promptTokens: 2, completionTokens: terminalCompletion,
                    prefixCacheHitTokens: 1)))
            // A duplicate terminal must not create a second work observation.
            continuation.yield(.finished(reason: .cancelled,
                usage: .init(promptTokens: 2, completionTokens: 99)))
        }
        continuation.finish()
        #expect(await budget.outstandingReservedBytes() > 0)
        #expect(budget.serviceBudget.count == 1)
        engine.retirement.release()
        let retirementLimit = ContinuousClock.now + .seconds(3)
        while await bridge._testPendingSubmissionCount() != 0,
            ContinuousClock.now < retirementLimit {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testPendingEngineIDCount() == 0)
        #expect(await bridge._testMappedRequestCount() == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(budget.serviceBudget.count == 0)
        let capacity = await bridge.backendSlotCapacity()
        #expect(capacity.telemetry?.generatedTokensTotal == Int64(max(2, terminalCompletion ?? 0)))
        #expect(capacity.telemetry?.generationRequestsTotal == 1)
        #expect(capacity.telemetry?.prefillRequestsTotal == 0)
        #expect(usageSignal.prefixCacheHitTokens == nil)
        #expect(capacity.performanceMeasurements?.decode == nil)
        let isolated = EnginePrefillReceipt(activity: activity, model: "other-model")
        #expect(!isolated.overlap.contended)
        isolated.end()
        await bridge.shutdown()
    }
}
