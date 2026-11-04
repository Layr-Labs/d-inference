import Foundation

/// Prefill scheduling only; token selection and request concurrency are separate.
/// Support must be advertised by the installed adapter and admitted natively.
public enum ClusterPrefillSchedule: String, Codable, CaseIterable, Sendable {
    case serial = "serial_v1"
    case oneChunkLookahead = "one_chunk_lookahead_v1"

    /// The schedule a placement in `mode` prefills with, of the model's `supported` ones (serial first). Tensor
    /// parallel prefills serially: every tensor-parallel runtime admits only `serial` (a Gemma 4 or MiMo pair planned
    /// with the lookahead was refused at load, 2026-11-03). A layer split takes the one-chunk lookahead where the
    /// model has it, never slower than serial for the same placement.
    public static func planned(for mode: ClusterGenerationMode, supported: [ClusterPrefillSchedule]) -> ClusterPrefillSchedule {
        if mode.usesTensorParallelPrefill { return .serial }
        return supported.contains(.oneChunkLookahead) ? .oneChunkLookahead : supported.first ?? .serial
    }
}
