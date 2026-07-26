import Foundation

/// What a benchmark phase was ASKED FOR versus what it actually BUILT.
///
/// Every `darkbloom benchmark` mode that constructs an engine records one of
/// these, because every one of them can measure a backend nobody selected:
/// `--kv-backend auto` resolves CONTIGUOUS (the v0.8.0 flip to paged was
/// reverted — paged is opt-in), and an explicit `paged` can still be vetoed
/// by the fleet kill switch. A phase that cannot name its backend produces
/// numbers that belong to no arm.
///
/// One shape across the sweep, the scheduler-prefill run, and the arrival
/// benchmark, so `scripts/gemma_contbatch` parses one vocabulary: the kind is
/// the leading word of a descriptor, and a degrade carries a
/// `(fallback: <reason>)` tail — see
/// `EngineV2Factory.ProductionBuild.resolvedKVBackendDescriptor`.
public struct BenchmarkKVBackend: Codable, Sendable {
    /// The `--kv-backend` selection the run was launched with:
    /// "auto" | "contiguous" | "paged".
    public let selection: String
    /// Distinct resolved-backend descriptors across every engine this phase
    /// built, in first-seen order. EMPTY means no engine was ever built.
    /// More than one entry means the phase measured a MIXED population and
    /// its numbers cannot be read as one backend's.
    public let resolved: [String]

    public init(selection: String, resolved: [String]) {
        self.selection = selection
        self.resolved = resolved
    }
}
