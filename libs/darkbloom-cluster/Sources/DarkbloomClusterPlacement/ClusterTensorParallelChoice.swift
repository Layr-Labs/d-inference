import DarkbloomClusterProtocol

/// How a family's tensor-parallel plan is weighed against the pipeline when
/// the provider's placement step puts tensor parallel first
/// (`ClusterPlacementPolicy.tensorParallelFirst`, owner 2026-10-24: "if tensor
/// fits it will and should always be faster"). A family states it in its plan
/// (`ClusterTensorParallelFamilyPlan.choice`); nil, every family before it
/// (Qwen, GLM), keeps that rule exactly.
///
/// To opt a family in, pass `choice: .fastest` where its placement family
/// builds `ClusterTensorParallelFamilyPlan` (`Gemma4PlacementFamily` does);
/// nothing else changes. Its layouts then encode `"choice":"fastest_v1"` in
/// the plan, so regenerate its golden layouts with it.
public enum ClusterTensorParallelChoice: String, Codable, Sendable {
    /// Chosen only where predicted faster than the best placement in any other
    /// mode by `ClusterPlacementPolicy.tensorParallelMargin`, as the planner's
    /// own comparison chooses (owner policy 2026-11-01: the fastest plan, not
    /// tensor parallel first), and held to the mode the pair keeps
    /// (`ClusterPlacementPolicy.keptMode`) like any other mode. The comparison
    /// reads the pair's measured link (`ClusterLinkProbeHistory`) and share
    /// probes (`ClusterShareProbeHistory`); before any load measured the link,
    /// a first placement prices tensor parallel on `assumedReduction` and the
    /// pipeline's transfers as free, so a pipeline is chosen unless tensor
    /// parallel is faster even then.
    ///
    /// The prediction must also rest on every rank's measured share step
    /// (`ClusterDecodeSplit.measured`: a share probe of this model, or the
    /// shard rates requests this build served in tensor parallel corrected).
    /// The hardware prior alone (`ClusterHardwarePrior`) never chooses it: the
    /// device index times each operation with its launch latency inside, so
    /// it overstates the weight time a rank halves. A placement predicted
    /// faster on the prior keeps the best other mode
    /// (`ClusterTensorParallelAssessment.Verdict.predictedFasterOnPriorOnly`).
    case fastest = "fastest_v1"

    /// The reduction a first placement of a `fastest` family assumes before a
    /// load measured the link: a sealed all-sum at the slow end of what pairs
    /// measured (27-29 us at 16 KB on two M5 Ultra over Thunderbolt 5,
    /// 2026-10-31; 43-109 us on another pair, 2026-10-23), the figures
    /// `ClusterForcedMode.assumedReduction` assumes. Labelled as assumed.
    public static let assumedReduction = ClusterReductionCost(fixedSeconds: ClusterForcedMode.assumedReduction.fixedSeconds,
        secondsPerByte: ClusterForcedMode.assumedReduction.secondsPerByte, keyed: true,
        provenance: "assumed, not measured: no load has measured this link yet, so tensor parallel is priced at a slow sealed "
            + "all-sum (0.1 ms fixed, 2.5 GB/s) and chosen only where it is predicted faster even then")
}
