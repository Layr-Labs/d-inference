import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Public packets only. The member constructs this AFTER the coordinator's
/// committed owner-start on its live connection; this value is not approval.
/// The configured owner independently validates the start before taking a lease.
public final class ClusterOwnerNativeKeyRelay: @unchecked Sendable {
    public let start: ClusterNativeAuthorizationStart
    public let deadlineUptimeNanoseconds: UInt64
    private let exchangeBody: @Sendable (UInt64, Data) throws -> Data
    private let cancellation: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false
    public init(start: ClusterNativeAuthorizationStart, deadlineUptimeNanoseconds: UInt64,
                exchange: @escaping @Sendable (UInt64, Data) throws -> Data,
                cancel: @escaping @Sendable () -> Void) throws {
        guard deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds else {
            throw ClusterOwnerStateError.invalid("Native key relay deadline expired")
        }
        self.start = start; self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        exchangeBody = exchange; cancellation = cancel
    }
    func requireBinding(identity: ClusterWorkerIdentity, rank: Int, plan: String) throws {
        guard start.common.epoch == identity.membershipEpoch, start.rank == rank,
              start.common.planSHA256.map({ String(format: "%02x", $0) }).joined() == plan,
              start.common.artifactSHA256.map({ String(format: "%02x", $0) }).joined() == identity.artifactSHA256 else {
            throw ClusterOwnerStateError.invalid("Native key relay binding differs")
        }
    }
    func exchange(sequence: UInt64, bytes: Data) throws -> Data {
        guard lock.withLock({ !cancelled }) else { throw ClusterWorkerOwnerErrorProxy.closed }
        try ClusterOwnerBootstrapProfile.nativeKeyPrelude.validate(sequence: sequence, contribution: bytes)
        let reply = try exchangeBody(sequence, bytes)
        try ClusterOwnerBootstrapProfile.nativeKeyPrelude.validateReply(sequence: sequence, contribution: bytes, reply: reply)
        guard lock.withLock({ !cancelled }) else { throw ClusterWorkerOwnerErrorProxy.closed }
        return reply
    }
    func cancel() {
        let notify = lock.withLock { if cancelled { return false }; cancelled = true; return true }
        if notify { cancellation() }
    }
}
