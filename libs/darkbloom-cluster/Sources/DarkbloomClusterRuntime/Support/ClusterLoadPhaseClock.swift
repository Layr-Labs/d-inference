import Foundation

/// Red control stub of #2437's load-phase clock: the same interface, and nothing is recorded.
public enum ClusterLoadPhaseClock {
    public enum Phase: String, CaseIterable, Sendable {
        case jacclGroup = "jaccl_group"
        case dataPlaneKeying = "data_plane_keying"
        case linkProbe = "link_probe"
        case checkpointVerify = "checkpoint_verify"
        case weightRead = "weight_read"
        case weightCopy = "weight_copy"
        case weightEvaluate = "weight_evaluate"
    }

    public struct Total: Sendable, Equatable {
        public var nanoseconds: UInt64
        public var count: Int
        public init(nanoseconds: UInt64 = 0, count: Int = 0) { self.nanoseconds = nanoseconds; self.count = count }
        public var milliseconds: UInt64 { nanoseconds / 1_000_000 }
    }

    public static var totals: [Phase: Total] { [:] }

    public static func add(_ phase: Phase, nanoseconds: UInt64) {}

    @discardableResult
    static func time<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T { try body() }
}
