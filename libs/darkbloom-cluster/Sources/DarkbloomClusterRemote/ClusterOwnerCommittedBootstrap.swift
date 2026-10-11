import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// The combined owner profile (S07) for a start the coordinator committed to
/// one member (S10).
///
/// Each member launches its own owner for its own rank, so no single process
/// holds both ranks' starts the way the leader's `ClusterOwnerBootstrapRelay`
/// does. The rounds therefore travel two ways:
/// - the native key prelude (rounds 0-2) goes through the member's own
///   coordinator session (`native_pair_hello`, `native_pair_binding`,
///   `native_pair_confirmation`, `native_pair_peer_confirmation`; round 2 is
///   local), which is what lets the coordinator count the session as
///   established;
/// - the JACCL mesh rounds (3-6) go to the mesh exchange the member's serving
///   host attaches once it serves the start, numbered from 0 there: on the
///   leader the pair's mesh-only relay, on the follower the link proxy to that
///   relay (S08). A mesh round waits, within the deadline, until one is
///   attached.
/// The owner on the other side admits the start itself (its installed
/// approval); nothing here is approval.
public final class ClusterOwnerCommittedBootstrap: ClusterOwnerBootstrapExchange, @unchecked Sendable {
    public let profile: ClusterOwnerBootstrapProfile = .nativeKeyPreludeMesh2
    public let identity: ClusterWorkerIdentity
    public let executionPlanSHA256: String
    public let deadlineUptimeNanoseconds: UInt64
    public let start: ClusterNativeAuthorizationStart
    private let prelude: @Sendable (UInt64, Data) throws -> Data
    private let invalidated: @Sendable () -> Void
    private let condition = NSCondition()
    private var mesh: (any ClusterOwnerBootstrapExchange)?
    private var cancelled = false
    private var next: UInt64 = 0

    /// `prelude` exchanges one prelude round through the member's session and
    /// returns its reply; `invalidated` is told once when the bootstrap fails
    /// or is cancelled.
    public init(start: ClusterNativeAuthorizationStart, identity: ClusterWorkerIdentity, executionPlanSHA256: String,
                deadlineUptimeNanoseconds: UInt64, prelude: @escaping @Sendable (UInt64, Data) throws -> Data,
                invalidated: @escaping @Sendable () -> Void) throws {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        guard deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds, identity.peers.count == 2,
              identity.peers.indices.contains(start.rank), start.common.epoch == identity.membershipEpoch,
              hex(start.common.planSHA256) == executionPlanSHA256,
              hex(start.common.artifactSHA256) == identity.artifactSHA256 else {
            throw OwnerWire.invalid("Committed start differs from the bootstrap's membership")
        }
        self.start = start; self.identity = identity; self.executionPlanSHA256 = executionPlanSHA256
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds; self.prelude = prelude; self.invalidated = invalidated
    }

    public func nativeStart(rank: Int) -> ClusterNativeAuthorizationStart? { rank == start.rank ? start : nil }

    /// Where the mesh rounds go: a mesh-only exchange of the same membership.
    /// Once; a cancelled bootstrap cancels what is attached.
    public func attachMesh(_ exchange: any ClusterOwnerBootstrapExchange) throws {
        guard exchange.profile == .mesh2, exchange.identity == identity,
              exchange.executionPlanSHA256 == executionPlanSHA256 else {
            throw OwnerWire.invalid("Mesh exchange differs from the committed bootstrap")
        }
        let refused = condition.withLock { () -> Bool in
            guard mesh == nil, !cancelled else { return true }
            mesh = exchange; condition.broadcast(); return false
        }
        if refused { exchange.cancel(); throw OwnerWire.invalid("Mesh exchange already attached or bootstrap cancelled") }
    }

    public var meshAttached: Bool { condition.withLock { mesh != nil } }

    public func cancel() {
        let (first, attached) = condition.withLock { () -> (Bool, (any ClusterOwnerBootstrapExchange)?) in
            let first = !cancelled; cancelled = true; condition.broadcast(); return (first, mesh)
        }
        guard first else { return }
        attached?.cancel()
        invalidated()
    }

    public func exchange(binding: ClusterOwnerBinding, sequence: UInt64, contribution: Data) throws -> Data {
        do {
            try condition.withLock {
                guard !cancelled, sequence == next, binding.rank == start.rank, binding.identity == identity,
                      binding.executionPlanSHA256 == executionPlanSHA256,
                      binding.route.ownerIncarnation == start.ownerIncarnation, binding.route.leaseID == start.leaseID,
                      DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
                    throw OwnerWire.invalid("Bootstrap owner, round or deadline differs from the committed start")
                }
                next += 1
            }
            try profile.validate(sequence: sequence, contribution: contribution)
            let reply: Data
            if profile.isPrelude(sequence) {
                if sequence == 0 {
                    let hello = try ClusterNativeKeyHello(encoded: contribution)
                    guard hello.start.canonicalBytes == start.canonicalBytes else { throw OwnerWire.invalid("Native hello names another start") }
                }
                reply = try prelude(sequence, contribution)
            } else {
                let exchange = try attachedMesh()
                reply = try exchange.exchange(binding: binding, sequence: sequence - UInt64(profile.preludeRounds),
                    contribution: contribution)
            }
            try profile.validateReply(sequence: sequence, contribution: contribution, reply: reply)
            return reply
        } catch {
            cancel()
            throw error
        }
    }

    private func attachedMesh() throws -> any ClusterOwnerBootstrapExchange {
        condition.lock(); defer { condition.unlock() }
        while !cancelled && mesh == nil && DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard !cancelled, let mesh else { throw ClusterWorkerOwnerErrorProxy.deadline }
        return mesh
    }
}
