import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Production, 2026-11-01: retiring a pair slot (`EngineV2Bridge.shutdown`)
/// cancelled a request's stream consumer while the engine queue published the
/// pair's peer loss to that consumer. Cancellation runs its handlers holding
/// the task's status lock; the stream's termination waited for the engine
/// queue, and the queue waited for that lock to resume the consumer. Every
/// wait here is bounded and polled, so a regression fails instead of hanging.
/// Fabricated owner only: no model, GPU or peer process.
@Suite(.timeLimit(.minutes(1)))
struct DistributedCBv2CancellationDeadlockTests {
    @Test func cancellingAConsumerWhileItsPeerLossIsPublishedCannotDeadlock() async throws {
        let owner = HeldReadinessOwner()
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.base.identity,
            profile: distributedTestProfile(), detokenizers: DistributedTestDetokenizers())
        let stream = try engine.submit(distributedTestRequest(maxTokens: 8))
        let lease = owner.base.last
        let probe = DeadlockProbe()
        // The consumer (the bridge's pump) takes a token, then waits in the stream.
        let consumer = Task {
            var events = stream.makeAsyncIterator()
            _ = await events.next()
            probe.mark("first token")
            while await events.next() != nil {}
            probe.mark("consumer ended")
        }
        #expect(lease.send(.token(4)))
        #expect(await probe.wait("first token", seconds: 5))
        try await Task.sleep(for: .milliseconds(200))

        // The next token holds the engine queue in its readiness check, which
        // then reports the peer lost: a failure published to the consumer.
        let release = owner.holdNextReadiness(probe)
        DispatchQueue.global().async { _ = lease.send(.token(5)); probe.mark("token returned") }
        #expect(await probe.wait("queue held", seconds: 5))
        // Meanwhile the owner invalidates and the slot's retirement cancels the consumer.
        DispatchQueue.global().async { owner.base.losePeer(); probe.mark("invalidation returned") }
        DispatchQueue.global().async { consumer.cancel(); probe.mark("cancel returned") }
        _ = await probe.wait("cancel returned", seconds: 1)
        release.signal()

        var ended = true
        for mark in ["cancel returned", "token returned", "invalidation returned", "consumer ended"] {
            let reached = await probe.wait(mark, seconds: 5)
            #expect(reached, "\(mark): the consumer's cancellation and the engine queue deadlocked")
            ended = ended && reached
        }
        // A deadlocked engine is left as it is: its queue would hang the suite.
        guard ended else { return }
        #expect(lease.cancelCount == 1) // the peer loss took the failure path, once
        lease.acknowledge()
        await engine.shutdown()
        #expect(lease.releaseCount == 1)
        #expect(owner.base.shutdownCount == 1)
    }

    /// The same lock order through the admission cancellation: a submission
    /// that waits for its refused reservation's retirement is cancelled while
    /// the engine queue retires it and resumes that submission.
    @Test func cancellingASubmissionWhileItsRetirementResumesItCannotDeadlock() async throws {
        let owner = HeldReadinessOwner()
        let clock = DistributedTestClock()
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.base.identity,
            profile: distributedTestProfile(), detokenizers: DistributedTestDetokenizers(), clock: clock.clock)
        owner.base.onReserve = { clock.advance(.seconds(5)) } // refused after reserve: the deadline passed
        let probe = DeadlockProbe()
        let submission = Task {
            _ = try? await engine.submit(distributedTestRequest(),
                firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
            probe.mark("submission ended")
        }
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while (owner.base.reserveCount == 0 || owner.base.last.cancelCount == 0) && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        let lease = owner.base.last
        #expect(lease.cancelCount == 1)
        try await Task.sleep(for: .milliseconds(200)) // the submission now waits for the retirement

        // The retirement holds the engine queue while it releases the
        // reservation, then resumes the submission; the caller cancels meanwhile.
        let release = owner.holdNextRelease(probe)
        lease.acknowledge()
        #expect(await probe.wait("queue held", seconds: 5))
        DispatchQueue.global().async { submission.cancel(); probe.mark("cancel returned") }
        _ = await probe.wait("cancel returned", seconds: 1)
        release.signal()

        var ended = true
        for mark in ["cancel returned", "submission ended"] {
            let reached = await probe.wait(mark, seconds: 5)
            #expect(reached, "\(mark): the submission's cancellation and the engine queue deadlocked")
            ended = ended && reached
        }
        guard ended else { return }
        #expect(lease.releaseCount == 1)
        #expect(lease.startCount == 0)
        await engine.shutdown()
        #expect(owner.base.shutdownCount == 1)
    }
}

/// Marks set from any thread, awaited by polling: no cooperative thread ever
/// waits on a queue that may be deadlocked.
private final class DeadlockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marks = Set<String>()

    func mark(_ name: String) { _ = lock.withLock { marks.insert(name) } }

    func wait(_ name: String, seconds: Double) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !lock.withLock({ marks.contains(name) }) && ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { marks.contains(name) }
    }
}

/// One held step: it marks the probe, then waits (bounded) for the test.
private final class HeldStep: @unchecked Sendable {
    private let lock = NSLock()
    private var next: (probe: DeadlockProbe, release: DispatchSemaphore)?

    func arm(_ probe: DeadlockProbe) -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        lock.withLock { next = (probe, release) }
        return release
    }

    /// True when this call was the held one.
    func pass() -> Bool {
        let held = lock.withLock { () -> (probe: DeadlockProbe, release: DispatchSemaphore)? in
            defer { next = nil }
            return next
        }
        guard let held else { return false }
        held.probe.mark("queue held")
        _ = held.release.wait(timeout: .now() + 30)
        return true
    }
}

/// The fabricated owner with one step held where the engine calls it on its
/// queue: a readiness check (`readyCapacity`), which then reports the peer
/// lost, or a reservation's release (`retire`).
private final class HeldReadinessOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let base = DistributedTestOwner()
    private let readinessStep = HeldStep()
    private let releaseStep = HeldStep()

    func holdNextReadiness(_ probe: DeadlockProbe) -> DispatchSemaphore { readinessStep.arm(probe) }
    func holdNextRelease(_ probe: DeadlockProbe) -> DispatchSemaphore { releaseStep.arm(probe) }

    func readiness() -> DistributedResidentReadiness? {
        if readinessStep.pass() { base.losePeer(notify: false) }
        return base.readiness()
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        base.setReadinessInvalidationHandler(handler)
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        base.projectFirstToken(request, admission: admission)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        HeldReleaseLease(try base.reserve(request, identity: identity, profileID: profileID,
            capacityLimit: capacityLimit), release: releaseStep)
    }
    func shutdown() async { await base.shutdown() }
}

/// The fabricated lease, its release held when the owner armed it.
private final class HeldReleaseLease: DistributedResidentRequestLease, @unchecked Sendable {
    private let inner: any DistributedResidentRequestLease
    private let release: HeldStep

    init(_ inner: any DistributedResidentRequestLease, release: HeldStep) { self.inner = inner; self.release = release }

    var identity: DistributedResidentIdentity { inner.identity }
    var requestID: CBv2RequestID { inner.requestID }
    var reservedBytes: Int { inner.reservedBytes }
    var bytesInUse: Int { inner.bytesInUse }
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws { try inner.start(emit: emit) }
    func cancel() { inner.cancel() }
    func requestCleanStop() -> Bool { inner.requestCleanStop() }
    func waitUntilRetired() async { await inner.waitUntilRetired() }
    func releaseResources() { _ = release.pass(); inner.releaseResources() }
}
