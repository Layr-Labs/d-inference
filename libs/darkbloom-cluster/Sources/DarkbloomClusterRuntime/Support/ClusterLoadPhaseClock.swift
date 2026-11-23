import Foundation

/// Where a resident load spends its time, by phase, for the worker's start-up
/// record (`darkbloom-owner-phases-v1`, `darkbloom-load-memory-v1`). Measured on
/// the uptime clock (`DispatchTime`), never the wall clock. A record only:
/// nothing reads it to make a decision, and recording changes no load.
///
/// The phases are timed where every adapter passes through them, so each
/// family's load is covered without a call of its own: the JACCL group
/// (`Collective`), the data-plane keying with the peer
/// (`ClusterDataPlaneAgreement`), the link probe, the checkpoint verification
/// (`VerifiedCheckpoint`, every file of the artifact hashed), and per tensor
/// the file read and the copy into MLX's storage (`TensorDescriptor.read`), and
/// the Qwen layer-stage materializer's evaluation and GPU wait. Each phase
/// sums every pass in this process (a phase split's two stages, a head).
public enum ClusterLoadPhaseClock {
    public enum Phase: String, CaseIterable, Sendable {
        /// The JACCL group's creation, with the owner's mesh rounds when it bootstraps through them.
        case jacclGroup = "jaccl_group"
        /// The keyed data plane's exchange with the peer (S16).
        case dataPlaneKeying = "data_plane_keying"
        /// The link measured at load, before any weight is read.
        case linkProbe = "link_probe"
        /// Hashing the artifact's files against its manifest.
        case checkpointVerify = "checkpoint_verify"
        /// Tensor bytes read from the verified files into host memory.
        case weightRead = "weight_read"
        /// Host bytes copied into MLX-owned (Metal) storage.
        case weightCopy = "weight_copy"
        /// Each stage tensor's evaluation and the GPU wait after it.
        case weightEvaluate = "weight_evaluate"
    }

    public struct Total: Sendable, Equatable {
        public var nanoseconds: UInt64
        public var count: Int
        public init(nanoseconds: UInt64 = 0, count: Int = 0) { self.nanoseconds = nanoseconds; self.count = count }
        public var milliseconds: UInt64 { nanoseconds / 1_000_000 }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [Phase: Total] = [:]

    /// Every phase recorded so far in this process.
    public static var totals: [Phase: Total] { lock.withLock { values } }

    /// Adds one pass of `phase`.
    public static func add(_ phase: Phase, nanoseconds: UInt64) {
        lock.withLock {
            var value = values[phase] ?? Total()
            value.nanoseconds &+= nanoseconds; value.count += 1
            values[phase] = value
        }
    }

    /// Runs `body` and adds its duration to `phase`, also when it throws.
    @discardableResult
    static func time<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { add(phase, nanoseconds: DispatchTime.now().uptimeNanoseconds &- started) }
        return try body()
    }
}
