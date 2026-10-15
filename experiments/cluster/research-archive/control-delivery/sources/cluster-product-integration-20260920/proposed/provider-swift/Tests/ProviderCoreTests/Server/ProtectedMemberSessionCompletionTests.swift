import Foundation
import Testing
@testable import ProviderCore

@Suite struct ProtectedMemberSessionCompletionTests {
    @Test func everyOriginalBarrierIsRequired() {
        let epoch = UUID()
        for mask in 0...127 { #expect(protectedCompletion(epoch, mask: mask).released == (mask == 127)) }
    }
    @Test func terminalObservationIsSinglePublication() async {
        let signal = NativePairSessionCompletionSignal(), epoch = UUID()
        let failed = protectedCompletion(epoch, mask: 63)
        async let first = signal.wait()
        async let second = signal.wait()
        signal.complete(failed); signal.complete(protectedCompletion(epoch))
        let values = await (first, second)
        #expect(values.0 == failed); #expect(values.1 == failed)
        #expect(signal.observation == failed)
    }
    @Test func requestOwnerShutdownAloneNeverAllowsRotation() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        try await session.start()
        let status = await session.stop(until: localHostDeadline(20))
        #expect(status == .quarantined); #expect(!session.httpCanRotate)
        #expect(backend.actualOwner.base.shutdownCount > 0)
        backend.publish(protectedCompletion(backend.epoch, mask: 63)) // aggregate proof absent
        await session.shutdown()
        #expect(session.status == .quarantined); #expect(!session.httpCanRotate)
    }
    @Test func missingACKAbnormalExitAndUnjoinedSignerEachStayQuarantined() async throws {
        for missing in [2, 4, 16] {
            let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
            try await session.start()
            backend.publish(protectedCompletion(backend.epoch, mask: 127 ^ missing))
            let status = await session.stop(until: localHostDeadline())
            await session.shutdown()
            #expect(status == .quarantined); #expect(!session.httpCanRotate)
        }
    }
    @Test func completeProofFromAnotherEpochIsRejected() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        try await session.start(); backend.publish(protectedCompletion(UUID()))
        _ = await session.stop(until: localHostDeadline()); await session.shutdown()
        #expect(session.status == .quarantined); #expect(!session.httpCanRotate)
    }
    @Test func lateActualCompletionCanResolveTimeoutWithoutSynthesizingProof() async throws {
        let backend = ProtectedMemberTestBackend(), session = try protectedTestSession(backend)
        try await session.start()
        _ = await session.stop(until: localHostDeadline(10))
        #expect(!session.httpCanRotate)
        backend.publish(); await session.shutdown()
        #expect(session.status == .released); #expect(session.httpCanRotate)
    }
}
