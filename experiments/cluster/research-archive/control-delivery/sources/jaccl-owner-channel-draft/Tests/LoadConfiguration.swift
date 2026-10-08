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

    public init(identity: ClusterWorkerIdentity, modelDirectory: URL, rank: Int,
                stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                allocatorPolicy: QwenResidentAllocatorPolicy = .unchanged) {
        self.identity = identity; self.modelDirectory = modelDirectory
        self.rank = rank; self.stageCut = stageCut
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.allocatorPolicy = allocatorPolicy
    }
}

// CPU fixture stand-in: tests do not invoke an allocator or native runtime.
public enum QwenResidentAllocatorPolicy: Sendable { case unchanged, disableFreedBufferCache }
