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
    /// The same, naming the cause (bounded fixed text, never prompt or token
    /// text) for the record a remote owner keeps of this fence (S24).
    func requestNativeCleanup(reason: String)
    /// Both waits finish when nativeCleanupObserved is justified, or when no
    /// proof can arrive any more (the owner process or its transport is gone,
    /// or the owner's last possible proof is past): then they return with
    /// nativeCleanupObserved still false, and ownership stays unresolved. A
    /// return is never cleanup proof by itself.
    func waitForNativeCleanup()
    func waitUntilNativeCleanup() async
}

extension ClusterWorkerEndpoint {
    public func receiveWorkerEvent(until deadline: UInt64) throws -> ClusterWorkerEventFrame {
        try receiveWorkerEvent(until: deadline, cancelled: { false })
    }

    /// An endpoint that keeps no record of the cause fences as before.
    public func requestNativeCleanup(reason: String) { requestNativeCleanup() }

    /// Bounded form of waitForNativeCleanup. False means the proof did not
    /// arrive by `deadline`; it grants nothing and ownership stays retained.
    public func waitForNativeCleanup(until deadline: UInt64) -> Bool {
        while !nativeCleanupObserved {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            Thread.sleep(forTimeInterval: min(0.02, Double(deadline - now) / 1_000_000_000))
        }
        return true
    }
}

/// All methods delegate to the direct-child supervisor. No pipe, callback,
/// deadline, exit observation or event ordering is replaced. Requesting native
/// cleanup closes the child's command stream; it does not signal the child.
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
