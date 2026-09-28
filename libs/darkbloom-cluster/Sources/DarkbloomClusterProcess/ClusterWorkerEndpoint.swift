import Foundation
import DarkbloomClusterProtocol

/// One configured native rank, supervised by an owner. This interface carries
/// worker events, not arbitrary shell commands. Its current implementation is a
/// local direct child; a remote transport must authenticate its owning service.
public protocol ClusterWorkerEndpoint: AnyObject, Sendable {
    var expectedIdentity: ClusterWorkerIdentity { get }
    var expectedProfile: ClusterWorkerProfile { get }
    var rank: Int { get }
    var executionPlanSHA256: String { get }
    var readiness: ClusterWorkerReady? { get }

    /// Conservative ceiling on THIS caller Mac's uptime clock. A remote owner
    /// derives its own ceiling from remaining duration; do not forward uptime.
    var localLifetimeDeadlineUptimeNanoseconds: UInt64 { get }

    /// Actual native cleanup proof held by this endpoint's supervisor: observed
    /// child exit, or a definitive failed launch with no child. For a remote
    /// endpoint this requires the authenticated owner's matching native-terminal
    /// acknowledgement, bound to current membership/rank/owner/lease. SSH exit,
    /// socket EOF, a sent signal, timeout and request `retired` alone are NOT this.
    var nativeCleanupObserved: Bool { get }

    /// Delivery must be asynchronous and independent of IO pumps/user callbacks.
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)
    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame

    /// Requests native cancellation/fencing; return is not cleanup proof.
    func requestNativeCleanup()
    /// Both waits finish only when nativeCleanupObserved is justified. A remote
    /// connection loss must retain unresolved ownership instead of returning.
    func waitForNativeCleanup()
    func waitUntilNativeCleanup() async
}

extension ClusterWorkerEndpoint {
    public func receiveWorkerEvent(until deadline: UInt64) throws -> ClusterWorkerEventFrame {
        try receiveWorkerEvent(until: deadline, cancelled: { false })
    }
}

/// All methods delegate to the unchanged direct-child supervisor. No pipe,
/// callback, deadline, signal, exit observation or event ordering is replaced.
extension ClusterWorkerProcess: ClusterWorkerEndpoint {
    public var localLifetimeDeadlineUptimeNanoseconds: UInt64 { lifetimeDeadline }
    public var nativeCleanupObserved: Bool { observedExit }
    public func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        try send(command, requestID: requestID, deadline: deadline)
    }
    public func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        try next(until: deadline, cancelled: cancelled)
    }
    public func requestNativeCleanup() { fence() }
    public func waitForNativeCleanup() { waitForExit() }
    public func waitUntilNativeCleanup() async { await waitUntilExited() }
}
