import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Closed profile of the current native two-peer mesh. It is not an RDMA struct
/// implementation. The installed build must independently confirm its C ABI.
public enum ClusterOwnerBootstrapProfile: String, Sendable {
    case mesh2 = "jaccl_mesh2_i32le_destination32_v1"
    /// Development authorization only: no mesh, model or Ready publication.
    case nativeKeyPrelude = "native_key_prelude_v1"
    public var rounds: Int { self == .mesh2 ? 4 : 3 }
    func validate(sequence: UInt64, contribution: Data) throws {
        if self == .nativeKeyPrelude {
            switch sequence {
            case 0: _ = try ClusterNativeKeyHello(encoded: contribution)
            case 1, 2: guard contribution.count == 32 else { throw OwnerWire.invalid("Native public tag size differs") }
            default: throw OwnerWire.invalid("Native key round differs")
            }
            return
        }
        switch sequence {
        case 0: guard contribution == Data([2, 0, 0, 0]) else { throw OwnerWire.invalid("Mesh container length must be native int32 two") }
        case 1: guard contribution.count == 64 else { throw OwnerWire.invalid("Mesh destination payload must be two native32-byte entries") }
        case 2, 3: guard contribution == Data([0, 0, 0, 0]) else { throw OwnerWire.invalid("Mesh barrier must be native int32 zero") }
        default: throw OwnerWire.invalid("Unsupported mesh round or topology")
        }
    }
    func validateReply(sequence: UInt64, contribution: Data, reply: Data) throws {
        if self == .nativeKeyPrelude {
            switch sequence {
            case 0:
                let hello = try ClusterNativeKeyHello(encoded: contribution)
                let binding = try ClusterNativeKeyBinding(encoded: reply)
                guard binding.hellos[hello.start.rank].canonicalBytes == hello.canonicalBytes else {
                    throw OwnerWire.invalid("Native public binding changes local hello")
                }
            case 1: guard reply.count == 32 else { throw OwnerWire.invalid("Peer confirmation size differs") }
            case 2: guard reply == contribution else { throw OwnerWire.invalid("Key completion receipt differs") }
            default: throw OwnerWire.invalid("Native key reply sequence differs")
            }
        } else {
            guard reply.count == contribution.count * 2 else { throw OwnerWire.invalid("Mesh reply size differs") }
            for rank in 0..<2 { try validate(sequence: sequence,
                contribution: Data(reply.dropFirst(rank * contribution.count).prefix(contribution.count))) }
        }
    }
}

/// Root-controller coordination only. Native callback waits never run on an
/// endpoint reader, the owner's command loop, or a provider callback queue.
public final class ClusterOwnerBootstrapRelay: @unchecked Sendable {
    public let profile: ClusterOwnerBootstrapProfile
    public let identity: ClusterWorkerIdentity
    public let executionPlanSHA256: String
    public let deadlineUptimeNanoseconds: UInt64
    private let condition = NSCondition()
    private var bindings: [ClusterOwnerBinding?] = [nil, nil]
    private var pending: [Data?] = [nil, nil]
    private var returned: [Bool] = [false, false]
    private var active: [Bool] = [false, false]
    private var sequence: UInt64 = 0
    private var failed = false

    public init(identity: ClusterWorkerIdentity, executionPlanSHA256: String,
                profile: ClusterOwnerBootstrapProfile = .mesh2, deadlineUptimeNanoseconds: UInt64) throws {
        guard profile == .mesh2, identity.peers.count == 2, deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds,
              executionPlanSHA256.utf8.count == 64 else { throw OwnerWire.invalid("Invalid bootstrap relay configuration") }
        self.identity = identity; self.executionPlanSHA256 = executionPlanSHA256; self.profile = profile
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }
    public func cancel() { condition.lock(); failed = true; condition.broadcast(); condition.unlock() }
    public func exchange(binding: ClusterOwnerBinding, sequence requested: UInt64, contribution: Data) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        do {
            let rank = binding.rank
            guard binding.identity == identity, binding.executionPlanSHA256 == executionPlanSHA256,
                  !failed, !active[rank], DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else { throw OwnerWire.invalid("Bootstrap peer or concurrent round differs") }
            if let prior = bindings[rank] {
                guard prior.route == binding.route else { throw OwnerWire.invalid("Bootstrap owner lease/incarnation changed") }
            } else { bindings[rank] = binding }
            if let other = bindings[1 - rank] {
                guard other.profile == binding.profile, other.route.clusterID == binding.route.clusterID,
                      other.route.leaseID != binding.route.leaseID else { throw OwnerWire.invalid("Bootstrap common configuration differs") }
            }
            // A fast rank may arrive at the next round while the other returns
            // the prior reply. Do not admit it before the prior round is drained.
            while !failed && requested == sequence + 1 && returned[rank] { try wait() }
            guard !failed, requested == sequence, pending[rank] == nil else { throw OwnerWire.invalid("Bootstrap round replay or skip") }
            try profile.validate(sequence: requested, contribution: contribution)
            active[rank] = true; pending[rank] = contribution; condition.broadcast()
            while !failed && pending.contains(where: { $0 == nil }) { try wait() }
            guard !failed, DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds, let a = pending[0], let b = pending[1], a.count == b.count else { throw OwnerWire.invalid("Bootstrap rank lengths differ") }
            var result = a; result.append(b)
            returned[rank] = true; active[rank] = false
            if returned.allSatisfy({ $0 }) { pending = [nil, nil]; returned = [false, false]; sequence += 1; condition.broadcast() }
            return result
        } catch { failed = true; condition.broadcast(); throw error }
    }
    private func wait() throws {
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else { throw ClusterWorkerOwnerErrorProxy.deadline }
        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
    }
}
