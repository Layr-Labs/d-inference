import DarkbloomClusterProtocol
import Foundation

/// Process-local configuration. Build/peer labels are supplied bindings, not
/// native attestation. The enclosing worker must impose a hard process deadline.
public struct QwenResidentLoadConfiguration: Sendable {
    public let identity: ClusterWorkerIdentity
    public let modelDirectory: URL
    public let rank: Int
    public let stageCut: Int
    public let deadlineUptimeNanoseconds: UInt64
    public let allocatorPolicy: QwenResidentAllocatorPolicy
    public let prefillSchedule: ClusterPrefillSchedule
    /// The worker's rank lease, as the runtime's own configuration carries it.
    public let lease: ClusterLeaseDeadline?

    public init(identity: ClusterWorkerIdentity, modelDirectory: URL, rank: Int,
                stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                allocatorPolicy: QwenResidentAllocatorPolicy = .unchanged,
                prefillSchedule: ClusterPrefillSchedule = .serial,
                lease: ClusterLeaseDeadline? = nil) {
        self.lease = lease
        self.identity = identity; self.modelDirectory = modelDirectory
        self.rank = rank; self.stageCut = stageCut
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.allocatorPolicy = allocatorPolicy
        self.prefillSchedule = prefillSchedule
    }
}

// CPU fixture stand-in: tests do not invoke an allocator or native runtime.
public enum QwenResidentAllocatorPolicy: Sendable { case unchanged, disableFreedBufferCache }

// CPU fixture stand-in for the runtime's owner bootstrap slot. The actual one
// calls the pinned mlx-c bridge (BootstrapChecks runs it against that bridge);
// argument admission never installs an exchange.
public enum JACCLOwnerBootstrap {
    public typealias Exchange = @Sendable (UInt64, Data) throws -> Data
    public static func install(rank: Int, exchange: @escaping Exchange) throws {}
}
