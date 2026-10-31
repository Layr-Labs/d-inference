import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Closed profile of the current native two-peer mesh. It is not an RDMA struct
/// implementation. The installed build must independently confirm its C ABI.
///
/// Wire rounds are numbered across the whole bootstrap: a profile with a
/// prelude carries the native key prelude in rounds 0-2, and its mesh rounds
/// follow at 3-6. The local owner-child socket numbers the mesh rounds from 0
/// on its own (the prelude packets are not mesh rounds there).
public enum ClusterOwnerBootstrapProfile: String, Sendable {
    case mesh2 = "jaccl_mesh2_i32le_destination32_v1"
    /// Development authorization only: no mesh, model or Ready publication.
    case nativeKeyPrelude = "native_key_prelude_v1"
    /// The production profile (S07): the native key prelude authenticates both
    /// native workers to each other under the committed start (an X25519
    /// agreement bound to the start's epoch, plan, artifact, rank, owner
    /// incarnation, lease and launch), then the same connection carries the
    /// JACCL mesh2 rounds. JACCL opens no TCP side channel of its own: every
    /// mesh byte travels through both authenticated owners.
    case nativeKeyPreludeMesh2 = "native_key_prelude_then_jaccl_mesh2_v1"

    /// The most rounds any profile carries; the owner wire refuses a higher one.
    public static let maximumRounds = 7
    public var preludeRounds: Int { self == .mesh2 ? 0 : 3 }
    public var meshRounds: Int { self == .nativeKeyPrelude ? 0 : 4 }
    public var rounds: Int { preludeRounds + meshRounds }
    /// The open carries the committed native start for this rank.
    public var carriesNativeStart: Bool { self != .mesh2 }
    /// A worker launched under this profile may publish model readiness.
    public var publishesReadiness: Bool { self != .nativeKeyPrelude }
    /// The wire round of the local mesh round `round`.
    func wireSequence(meshRound round: UInt64) -> UInt64 { round + UInt64(preludeRounds) }
    func isPrelude(_ sequence: UInt64) -> Bool { sequence < UInt64(preludeRounds) }

    func validate(sequence: UInt64, contribution: Data) throws {
        guard sequence < UInt64(rounds) else { throw OwnerWire.invalid("Bootstrap round outside the profile") }
        if isPrelude(sequence) { try Self.validatePrelude(sequence: sequence, contribution: contribution) }
        else { try Self.validateMesh(sequence: sequence - UInt64(preludeRounds), contribution: contribution) }
    }
    func validateReply(sequence: UInt64, contribution: Data, reply: Data) throws {
        guard sequence < UInt64(rounds) else { throw OwnerWire.invalid("Bootstrap reply outside the profile") }
        if isPrelude(sequence) {
            try Self.validatePreludeReply(sequence: sequence, contribution: contribution, reply: reply)
        } else {
            let round = sequence - UInt64(preludeRounds)
            guard reply.count == contribution.count * 2 else { throw OwnerWire.invalid("Mesh reply size differs") }
            for rank in 0..<2 { try Self.validateMesh(sequence: round,
                contribution: Data(reply.dropFirst(rank * contribution.count).prefix(contribution.count))) }
        }
    }

    private static func validatePrelude(sequence: UInt64, contribution: Data) throws {
        switch sequence {
        case 0: _ = try ClusterNativeKeyHello(encoded: contribution)
        case 1, 2: guard contribution.count == 32 else { throw OwnerWire.invalid("Native public tag size differs") }
        default: throw OwnerWire.invalid("Native key round differs")
        }
    }
    private static func validatePreludeReply(sequence: UInt64, contribution: Data, reply: Data) throws {
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
    }
    private static func validateMesh(sequence: UInt64, contribution: Data) throws {
        switch sequence {
        case 0: guard contribution == Data([2, 0, 0, 0]) else { throw OwnerWire.invalid("Mesh container length must be native int32 two") }
        case 1: guard contribution.count == 64 else { throw OwnerWire.invalid("Mesh destination payload must be two native32-byte entries") }
        case 2, 3: guard contribution == Data([0, 0, 0, 0]) else { throw OwnerWire.invalid("Mesh barrier must be native int32 zero") }
        default: throw OwnerWire.invalid("Unsupported mesh round or topology")
        }
    }
}

/// The root controller's side of one bootstrap round, as an endpoint sees it.
/// The leader's own relay is one; a follower reached over the link control
/// channel uses a proxy that carries each round to the leader's relay.
public protocol ClusterOwnerBootstrapExchange: AnyObject, Sendable {
    var profile: ClusterOwnerBootstrapProfile { get }
    var identity: ClusterWorkerIdentity { get }
    var executionPlanSHA256: String { get }
    var deadlineUptimeNanoseconds: UInt64 { get }
    /// The committed native start for a rank, for a profile that carries one.
    func nativeStart(rank: Int) -> ClusterNativeAuthorizationStart?
    func exchange(binding: ClusterOwnerBinding, sequence: UInt64, contribution: Data) throws -> Data
    func cancel()
}

/// Root-controller coordination only. Native callback waits never run on an
/// endpoint reader, the owner's command loop, or a provider callback queue.
///
/// Mesh rounds return both contributions in rank order. Prelude rounds (the
/// combined profile only) return: the binding of both hellos (round 0, the
/// same bytes to both ranks), the other rank's confirmation tag (round 1),
/// and the agreed transcript digest (round 2, which must be equal).
public final class ClusterOwnerBootstrapRelay: ClusterOwnerBootstrapExchange, @unchecked Sendable {
    public let profile: ClusterOwnerBootstrapProfile
    public let identity: ClusterWorkerIdentity
    public let executionPlanSHA256: String
    public let deadlineUptimeNanoseconds: UInt64
    private let starts: [ClusterNativeAuthorizationStart]
    private let condition = NSCondition()
    private var bindings: [ClusterOwnerBinding?] = [nil, nil]
    private var pending: [Data?] = [nil, nil]
    private var returned: [Bool] = [false, false]
    private var active: [Bool] = [false, false]
    private var sequence: UInt64 = 0
    private var failed = false

    public init(identity: ClusterWorkerIdentity, executionPlanSHA256: String,
                profile: ClusterOwnerBootstrapProfile = .mesh2, deadlineUptimeNanoseconds: UInt64,
                nativeStarts: [ClusterNativeAuthorizationStart] = []) throws {
        guard profile != .nativeKeyPrelude, identity.peers.count == 2, deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds,
              executionPlanSHA256.utf8.count == 64 else { throw OwnerWire.invalid("Invalid bootstrap relay configuration") }
        if profile.carriesNativeStart {
            func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
            guard nativeStarts.count == 2, nativeStarts.map(\.rank) == [0, 1],
                  nativeStarts[0].common.canonicalBytes == nativeStarts[1].common.canonicalBytes,
                  nativeStarts[0].common.epoch == identity.membershipEpoch,
                  hex(nativeStarts[0].common.planSHA256) == executionPlanSHA256,
                  hex(nativeStarts[0].common.artifactSHA256) == identity.artifactSHA256,
                  nativeStarts[0].ownerIncarnation != nativeStarts[1].ownerIncarnation,
                  nativeStarts[0].leaseID != nativeStarts[1].leaseID,
                  nativeStarts[0].launchID != nativeStarts[1].launchID else {
                throw OwnerWire.invalid("Native starts differ from the bootstrap relay's membership")
            }
        } else {
            guard nativeStarts.isEmpty else { throw OwnerWire.invalid("Native starts given for a mesh-only profile") }
        }
        self.identity = identity; self.executionPlanSHA256 = executionPlanSHA256; self.profile = profile
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds; starts = nativeStarts
    }
    public func nativeStart(rank: Int) -> ClusterNativeAuthorizationStart? {
        starts.indices.contains(rank) ? starts[rank] : nil
    }
    public func cancel() { condition.lock(); failed = true; condition.broadcast(); condition.unlock() }
    public func exchange(binding: ClusterOwnerBinding, sequence requested: UInt64, contribution: Data) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        do {
            let rank = binding.rank
            guard binding.identity == identity, binding.executionPlanSHA256 == executionPlanSHA256,
                  !failed, !active[rank], DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else { throw OwnerWire.invalid("Bootstrap peer or concurrent round differs") }
            if let start = nativeStart(rank: rank) {
                guard binding.route.ownerIncarnation == start.ownerIncarnation, binding.route.leaseID == start.leaseID else {
                    throw OwnerWire.invalid("Bootstrap owner differs from its committed native start")
                }
            }
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
            if requested == 0, profile.carriesNativeStart {
                let hello = try ClusterNativeKeyHello(encoded: contribution)
                guard hello.start.rank == rank, hello.start.canonicalBytes == starts[rank].canonicalBytes else {
                    throw OwnerWire.invalid("Native hello names another start")
                }
            }
            active[rank] = true; pending[rank] = contribution; condition.broadcast()
            while !failed && pending.contains(where: { $0 == nil }) { try wait() }
            guard !failed, DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds, let a = pending[0], let b = pending[1] else {
                throw OwnerWire.invalid("Bootstrap round incomplete")
            }
            let result = try combine(sequence: requested, a, b, rank: rank)
            returned[rank] = true; active[rank] = false
            if returned.allSatisfy({ $0 }) { pending = [nil, nil]; returned = [false, false]; sequence += 1; condition.broadcast() }
            return result
        } catch { failed = true; condition.broadcast(); throw error }
    }
    /// Deterministic in both contributions, so both ranks compute the same
    /// binding and digest from the same bytes.
    private func combine(sequence: UInt64, _ a: Data, _ b: Data, rank: Int) throws -> Data {
        guard profile.isPrelude(sequence) else {
            guard a.count == b.count else { throw OwnerWire.invalid("Bootstrap rank lengths differ") }
            var result = a; result.append(b); return result
        }
        switch sequence {
        case 0:
            return try ClusterNativeKeyBinding(hellos: [ClusterNativeKeyHello(encoded: a), ClusterNativeKeyHello(encoded: b)]).canonicalBytes
        case 1: return rank == 0 ? b : a
        default:
            guard a == b else { throw OwnerWire.invalid("Native key transcripts differ") }
            return a
        }
    }
    private func wait() throws {
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else { throw ClusterWorkerOwnerErrorProxy.deadline }
        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
    }
}
