import DarkbloomClusterProtocol

/// DEVELOPER ONLY, never offered on a user's path: a deployment mode family
/// the planner is told to use instead of choosing one (`ClusterPlacementPolicy.forcedMode`).
/// The provider sets it from `DARKBLOOM_CLUSTER_FORCE_MODE` in a debug build
/// only, for pilots of a mode the planner cannot choose yet on a new pair
/// (tensor parallel needs a link a load measured and measured shard speeds).
/// Only placements of the forced family are considered; memory fit, the
/// model's own mode list (its stage adapter) and the qualification shapes
/// still decide, and a forced family that cannot be placed is refused with
/// the reason, never replaced by another family.
public enum ClusterForcedMode: String, Codable, Sendable, CaseIterable {
    case tensorParallel = "tensor_parallel_v1"
    /// The sharded pipeline family: plain, compact decode and MTP pipelines (never a hand-off mode).
    case pipeline = "pipeline_v1"

    /// Whether `mode` belongs to this family.
    public func admits(_ mode: ClusterGenerationMode) -> Bool {
        switch self {
        case .tensorParallel: mode == .tensorParallel
        case .pipeline: !mode.usesTensorParallelDecode && !mode.isHandOff
        }
    }

    /// The family in the words the screens use.
    public var words: String {
        switch self {
        case .tensorParallel: "tensor parallel"
        case .pipeline: "pipeline"
        }
    }

    /// The reduction a forced tensor-parallel plan assumes when no load has
    /// measured the link yet (or measured it unkeyed): about the sealed
    /// all-sum the bench measured at a decode step (73-101 us at 20 KB) and a
    /// prefill chunk's width. Labelled as assumed; the next plan uses the
    /// link the forced load measured (`ClusterWorkerLinkProbe`).
    public static let assumedReduction = ClusterReductionCost(fixedSeconds: 100e-6, secondsPerByte: 1 / 2.5e9, keyed: true,
        provenance: "assumed, not measured: a developer setting forced tensor parallel before a load measured this link "
            + "(about 0.1 ms per sealed all-sum at a decode step)")
}

extension ClusterLinkCosts {
    /// These costs with the forced plan's assumed reduction in place of a missing or unkeyed one.
    func assumingForcedReduction() -> ClusterLinkCosts {
        guard reduction?.keyed != true else { return self }
        return .init(measured: measured, perChunkSeconds: perChunkSeconds, perDecodeStepSeconds: perDecodeStepSeconds,
            handoffSecondsPerByte: handoffSecondsPerByte, provenance: provenance, reduction: ClusterForcedMode.assumedReduction)
    }
}
