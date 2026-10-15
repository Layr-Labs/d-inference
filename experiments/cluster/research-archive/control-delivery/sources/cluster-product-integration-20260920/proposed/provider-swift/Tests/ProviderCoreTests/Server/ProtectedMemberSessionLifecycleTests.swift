import Foundation
import Testing
@testable import ProviderCore

@Suite struct ProtectedMemberSessionLifecycleTests {
    @Test func savedBindingSurvivesWithoutInventingTransportDiagnostics() throws {
        let first = ProtectedMemberTestBackend(), second = ProtectedMemberTestBackend()
        let a = try protectedTestSession(first, binding: protectedTestBinding(first, configurationPin: "a"))
        let b = try protectedTestSession(second, binding: protectedTestBinding(second, configurationPin: "b"))
        #expect(a.httpDiagnosticObservation == nil)
        #expect(DistributedLocalSessionBinding(a).installed != nil)
        #expect(DistributedLocalSessionBinding(a) != DistributedLocalSessionBinding(b))
    }
    @Test func admissionDelegatesToSameOwnerAndIdentity() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        #expect(!session.httpAdmissionAvailable)
        try await session.start()
        let ready = try #require(session.readiness()), original = try #require(backend.actualOwner.readiness())
        #expect(ready.identity == original.identity && ready.profileID == original.profileID
            && ready.requestCapacityBytes == original.requestCapacityBytes)
        #expect(session.httpAdmissionAvailable)
        _ = try session.reserve(distributedTestRequest(), identity: session.expectedIdentity,
            profileID: session.profile.id, capacityLimit: 1024)
        #expect(backend.actualOwner.base.reserveCount == 1)
        backend.actualOwner.base.last.acknowledge()
        backend.publish(); _ = await session.stop(until: localHostDeadline()); await session.shutdown()
    }
    @Test func foreignIdentityOrProfileRefusesBeforeOriginalOwnerReserve() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        try await session.start()
        #expect(throws: DistributedEngineError.unavailable) {
            try session.reserve(distributedTestRequest(), identity: DistributedTestOwner().identity,
                profileID: session.profile.id, capacityLimit: 1024)
        }
        #expect(throws: DistributedEngineError.unavailable) {
            try session.reserve(distributedTestRequest(), identity: session.expectedIdentity,
                profileID: "changed", capacityLimit: 1024)
        }
        #expect(backend.actualOwner.base.reserveCount == 0)
        backend.publish(); _ = await session.stop(until: localHostDeadline()); await session.shutdown()
    }
    @Test func changedMetadataDuringStartClosesCapturedSession() async throws {
        let backend = ProtectedMemberTestBackend(), validation = ProtectedMemberValidationLatch()
        validation.rejectSecond = true
        let session = try protectedTestSession(backend, validate: { try validation.check() })
        await #expect(throws: DistributedEngineError.unavailable) { try await session.start() }
        let cancelled = try await localHostEventually { backend.cancelCount > 0 }
        #expect(cancelled); #expect(!session.httpAdmissionAvailable)
        backend.publish(protectedCompletion(backend.epoch, mask: 0)); await session.shutdown()
        #expect(!session.httpCanRotate)
    }
    @Test func stopWhileStartupValidationIsPausedCannotReopenAdmissions() async throws {
        let backend = ProtectedMemberTestBackend(), validation = ProtectedMemberValidationLatch()
        validation.holdSecond()
        let session = try protectedTestSession(backend, validate: { try validation.check() })
        let startup = Task.detached { try await session.start() }
        defer { validation.release() }
        await validation.entered.wait()
        _ = await session.stop(until: localHostDeadline(10))
        validation.release()
        await #expect(throws: DistributedEngineError.shuttingDown) { try await startup.value }
        #expect(!session.httpAdmissionAvailable)
        backend.publish(); await session.shutdown()
        #expect(session.httpCanRotate)
    }
    @Test func cancellationDuringValidationCannotPublishReady() async throws {
        let backend = ProtectedMemberTestBackend(), validation = ProtectedMemberValidationLatch()
        validation.holdSecond()
        let session = try protectedTestSession(backend, validate: { try validation.check() })
        let startup = Task.detached { try await session.start() }
        defer { validation.release() }
        await validation.entered.wait(); startup.cancel(); validation.release()
        await #expect(throws: CancellationError.self) { try await startup.value }
        #expect(!session.httpAdmissionAvailable)
        backend.publish(); await session.shutdown()
    }
    @Test func gracefulQuotaDrainWaitsAndExplicitStopInterruptsSameBackend() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        backend.holdDrain(); try await session.start(); backend.exhaust()
        #expect(session.httpSessionExhausted); #expect(!session.httpAdmissionAvailable)
        let draining = Task { await session.drain(until: localHostDeadline()) }
        let entered = try await localHostEventually { backend.drainCount == 1 }
        #expect(entered); #expect(backend.cancelCount == 0)
        #expect(!session.httpCanRotate)
        backend.publish()
        _ = await session.stop(until: localHostDeadline()); _ = await draining.value
        await session.shutdown()
        #expect(backend.cancelCount == 1); #expect(session.httpCanRotate)
    }
    @Test func normalQuotaDrainNeedsCompletionButDoesNotCancelTheMember() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        try await session.start(); backend.exhaust()
        let draining = Task { await session.drain(until: localHostDeadline()) }
        let entered = try await localHostEventually { backend.drainCount == 1 }
        #expect(entered); #expect(!backend.canAdmit); #expect(!session.httpCanRotate)
        #expect(backend.cancelCount == 0)
        backend.publish(); _ = await draining.value; await session.shutdown()
        #expect(backend.cancelCount == 0); #expect(session.httpCanRotate)
    }
    @Test func disconnectedGenerationCannotBorrowReplacementCompletion() async throws {
        let old = ProtectedMemberTestBackend(), replacement = ProtectedMemberTestBackend()
        let session = try protectedTestSession(old)
        try await session.start(); old.disconnect(); replacement.publish()
        let cancelled = try await localHostEventually { old.cancelCount > 0 }
        #expect(cancelled); #expect(replacement.cancelCount == 0)
        #expect(session.httpSessionInvalid); #expect(!session.httpCanRotate)
        old.publish(protectedCompletion(old.epoch, mask: 63)); await session.shutdown()
        #expect(!session.httpCanRotate)
    }
}
