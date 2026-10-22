import Foundation

/// Internal lifecycle seam. The product implementation below wraps only the
/// already-claimed owner and exact original member session; fixtures own no child.
protocol ProtectedMemberSessionBackend: AnyObject, Sendable {
    var owner: any DistributedDeadlineExecutionOwner { get }
    var epoch: UUID { get }
    var lifetime: UInt64 { get }
    var canAdmit: Bool { get }
    var invalid: Bool { get }
    var exhausted: Bool { get }
    var completion: NativePairSessionCompletion? { get }
    func closeAdmissions()
    func cancel()
    func drain() async
    func waitForCompletion() async -> NativePairSessionCompletion
}

final class NativePairRetainedSession: ProtectedMemberSessionBackend, @unchecked Sendable {
    let session: NativePairMemberSession
    let requestOwner: NativePairRequestExecutionOwner
    init(session: NativePairMemberSession, owner: NativePairRequestExecutionOwner) {
        self.session = session; requestOwner = owner
    }
    var owner: any DistributedDeadlineExecutionOwner { requestOwner }
    var epoch: UUID { session.start.common.epoch }
    var lifetime: UInt64 { session.lifetimeDeadline }
    var canAdmit: Bool { requestOwner.admissionState.canAdmit() }
    var invalid: Bool { !requestOwner.admissionState.isValid }
    var exhausted: Bool {
        let state = requestOwner.admissionState
        return state.admissionsRemaining == 0 && !state.hasActiveRequest
    }
    var completion: NativePairSessionCompletion? { session.completion.observation }
    func closeAdmissions() { requestOwner.closeAdmissions() }
    func cancel() { session.cancel(notify: true) }
    func drain() async { await requestOwner.drain() }
    func waitForCompletion() async -> NativePairSessionCompletion { await session.completion.wait() }
}

/// A cancellation handle exists before claim waits for readiness. It retains the
/// exact original session even after Control disconnects or changes generation.
final class NativePairRetainedSessionClaim: @unchecked Sendable {
    private let session: NativePairMemberSession
    private let requireCurrent: @Sendable () throws -> Void
    init(session: NativePairMemberSession, requireCurrent: @escaping @Sendable () throws -> Void) {
        self.session = session; self.requireCurrent = requireCurrent
    }
    func cancel() { session.cancel(notify: true) }
    func claim(profile: DistributedResidentExecutionProfile, until deadline: UInt64) throws -> NativePairRetainedSession {
        do {
            try requireCurrent()
            let owner = try session.requestOwner(profile: profile, until: deadline)
            try requireCurrent()
            return .init(session: session, owner: owner)
        } catch { cancel(); throw error }
    }
}
