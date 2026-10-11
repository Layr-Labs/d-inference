import Foundation

/// What a cluster member reports, and which rule decides whether it serves.
///
/// A pair is not one Mac, so the single-Mac requirements of a model
/// (`ModelRuntimeRequirements`, for example the Qwen3.8 27B's `apple_m5` and
/// `mlx_nax`) are not applied to each member; they stay in force, unchanged,
/// for solo serving. A member is decided by the model's pair-serving grant
/// (`ClusterPairServingGrants`, owner decision D4): the chip classes each role
/// may run on, keyed by the runtime's own model identity and checked with the
/// class of the Mac that runs the rank (`ClusterMemberPreparation.prepare`,
/// and the owner of every rank before it serves).
/// A runtime capability, such as a claimed `mlx_nax`, is not an input to that
/// decision.
public enum DistributedServingEligibility {
    /// What a control-only member reports about itself: the detector's answer
    /// with no bound runtime and no kernel probe. Registration only; it opens
    /// no pair.
    public static func memberCapabilities(chipFamily: ChipFamily) -> Set<ProviderRuntimeCapability> {
        ProviderRuntimeCapabilityDetector.detect(chipFamily: chipFamily, naxAvailable: { false }, liveMetallibHash: { nil })
    }
}
