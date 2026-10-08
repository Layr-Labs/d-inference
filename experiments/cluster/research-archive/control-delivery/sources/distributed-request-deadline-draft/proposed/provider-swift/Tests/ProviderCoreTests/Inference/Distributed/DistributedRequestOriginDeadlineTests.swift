import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private final class DeadlineOwner: DistributedDeadlineExecutionOwner, @unchecked Sendable {
    let base = DistributedTestOwner()
    private let lock = NSLock()
    private var value: DistributedRequestDeadlineContext?
    var context: DistributedRequestDeadlineContext? { lock.withLock { value } }
    func readiness() -> DistributedResidentReadiness? { base.readiness() }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) { base.setReadinessInvalidationHandler(handler) }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        base.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        throw DistributedEngineError.invalidConfiguration("deadline-aware path was bypassed")
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                 capacityLimit: Int, deadlineContext: DistributedRequestDeadlineContext) throws -> any DistributedResidentRequestLease {
        lock.withLock { value = deadlineContext }
        return try base.reserve(request, identity: identity, profileID: profileID, capacityLimit: capacityLimit)
    }
    func shutdown() async { await base.shutdown() }
}

private final class QueueCaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var reads = 0
    let captured = DispatchSemaphore(value: 0)
    var clock: CBv2Clock {
        CBv2Clock {
            let result = self.lock.withLock { () -> (ContinuousClock.Instant, Bool) in
                self.reads += 1
                return (self.instant, self.reads == 2)
            }
            if result.1 { self.captured.signal() }
            return result.0
        }
    }
    func advance(_ amount: Duration) { lock.withLock { instant = instant.advanced(by: amount) } }
}

@Suite(.timeLimit(.minutes(1)))
struct DistributedRequestOriginDeadlineTests {
    private func engine(_ owner: DeadlineOwner, _ clock: DistributedTestClock) throws -> DistributedCBv2Engine {
        try .init(owner: owner, expectedIdentity: owner.base.identity, profile: distributedTestProfile(),
                  detokenizers: DistributedTestDetokenizers(), clock: clock.clock)
    }

    private func finish(_ engine: DistributedCBv2Engine, _ owner: DeadlineOwner) async {
        if owner.base.reserveCount > 0 && owner.base.last.releaseCount == 0 {
            engine.cancel(owner.base.last.requestID); owner.base.last.acknowledge()
        }
        await engine.shutdown()
    }

    @Test func ordinarySubmitCapturesBudgetBeforeWaitingForEngineQueue() async throws {
        let owner = DeadlineOwner(), clock = QueueCaptureClock()
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.base.identity,
            profile: distributedTestProfile(), detokenizers: DistributedTestDetokenizers(), clock: clock.clock)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        engine.queue.async { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        defer { release.signal() }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let pending = Task.detached { try engine.submit(distributedTestRequest()) }
        // Both default context and profile-clamp reads occur before queue.sync.
        #expect(clock.captured.wait(timeout: .now() + 2) == .success)
        clock.advance(.seconds(315)); release.signal()
        do {
            _ = try await pending.value
            Issue.record("engine queue wait received a new budget")
        } catch DistributedRequestDeadlineError.generationExpired { }
        #expect(owner.base.reserveCount == 0)
        await finish(engine, owner)
    }

    @Test func preparationAndReserveTimeConsumeTheOriginalBudget() async throws {
        let owner = DeadlineOwner(), clock = DistributedTestClock()
        let engine = try engine(owner, clock)
        let context = engine.deadlineContext(receivedAt: clock.now)
        clock.advance(.seconds(300)) // provider preparation and queued work
        owner.base.onReserve = { clock.advance(.seconds(10)) }
        let stream = try engine.submit(distributedTestRequest(), deadlineContext: context)
        #expect(owner.context == context)
        #expect(engine.onQueue { engine.active?.absoluteDeadline } == context.generationDeadline)
        clock.advance(.seconds(5))
        #expect(!owner.base.last.send(.token(4)))
        #expect(owner.base.last.releaseCount == 0)
        owner.base.last.acknowledge()
        let terminal = distributedTerminal(await distributedCollect(stream))
        guard let terminal, case .terminal(let cause, _) = terminal.0 else { Issue.record("expected origin expiry"); return }
        #expect(cause == .safetyDeadline)
        await finish(engine, owner)
    }

    @Test func expiredOriginDoesNotReserve() async throws {
        let owner = DeadlineOwner(), clock = DistributedTestClock()
        let engine = try engine(owner, clock)
        let context = engine.deadlineContext(receivedAt: clock.now)
        clock.advance(.seconds(315))
        #expect(throws: DistributedRequestDeadlineError.generationExpired) {
            _ = try engine.submit(distributedTestRequest(), deadlineContext: context)
        }
        #expect(owner.base.reserveCount == 0)
        await finish(engine, owner)
    }

    @Test func callerCannotEnlargeProfileCeiling() async throws {
        let owner = DeadlineOwner(), clock = DistributedTestClock()
        let engine = try engine(owner, clock), now = clock.now
        let stream = try engine.submit(distributedTestRequest(maxTokens: 1),
            deadlineContext: .init(generationDeadline: now.advanced(by: .seconds(600))))
        #expect(owner.context?.generationDeadline == now.advanced(by: .seconds(315)))
        owner.base.last.send(.token(4)); owner.base.last.acknowledge()
        _ = await distributedCollect(stream); await finish(engine, owner)
    }

    @Test func firstTokenExpiryIsNotGenerationExpiryAfterFirstToken() async throws {
        let owner = DeadlineOwner(), clock = DistributedTestClock()
        let engine = try engine(owner, clock), now = clock.now
        let context = DistributedRequestDeadlineContext(generationDeadline: now.advanced(by: .seconds(20)),
                                                        firstTokenDeadline: now.advanced(by: .seconds(2)))
        let stream = try engine.submit(distributedTestRequest(), deadlineContext: context)
        #expect(owner.base.last.send(.token(4)))
        clock.advance(.seconds(3))
        #expect(!owner.base.last.send(.token(5))) // clean length at token 2
        #expect(owner.base.last.cancelCount == 0)
        owner.base.last.acknowledge()
        #expect(distributedTerminal(await distributedCollect(stream))?.0 == .length)
        await finish(engine, owner)
    }

    @Test func firstTokenExpiryDuringUnprojectedReserveDoesNotStart() async throws {
        let owner = DeadlineOwner(), clock = DistributedTestClock()
        let engine = try engine(owner, clock), now = clock.now
        owner.base.onReserve = { clock.advance(.seconds(3)) }
        let stream = try engine.submit(distributedTestRequest(), deadlineContext: .init(
            generationDeadline: now.advanced(by: .seconds(20)), firstTokenDeadline: now.advanced(by: .seconds(2))))
        #expect(owner.base.last.startCount == 0 && owner.base.last.cancelCount == 1)
        #expect(owner.base.last.releaseCount == 0)
        owner.base.last.acknowledge()
        let terminal = distributedTerminal(await distributedCollect(stream))
        guard let terminal, case .terminal(let cause, _) = terminal.0 else { Issue.record("expected admission expiry"); return }
        #expect(cause == .admissionTimeout)
        await finish(engine, owner)
    }
}
