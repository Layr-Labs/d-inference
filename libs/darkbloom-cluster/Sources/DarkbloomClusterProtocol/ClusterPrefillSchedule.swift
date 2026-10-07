import Foundation

/// Prefill scheduling only; token selection and request concurrency are separate.
/// Support must be advertised by the installed adapter and admitted natively.
public enum ClusterPrefillSchedule: String, Codable, CaseIterable, Sendable {
    case serial = "serial_v1"
    case oneChunkLookahead = "one_chunk_lookahead_v1"
}
