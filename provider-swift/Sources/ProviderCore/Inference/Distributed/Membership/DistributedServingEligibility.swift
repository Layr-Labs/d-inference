import Foundation

/// What a cluster member reports, and which rule decides whether it serves.
///
/// A pair is not one Mac, so the single-Mac requirements of a model
/// (`ModelRuntimeRequirements`, for example the Qwen3.8 27B's `apple_m5` and
/// `mlx_nax`) are not applied to each member; they stay in force, unchanged,
/// for solo serving. A member is decided by the owner's serving rule
/// (`ClusterPairServingGrants.requireRank`, owner 2026-10-14 08:45): any
/// model a cluster stage adapter runs, on any Apple silicon, keyed by the
/// runtime's own model identity and checked with the class of the Mac that
/// runs the rank against the shapes a diverged record steers away from
/// (`ClusterMemberPreparation.prepare`, and the owner of every rank before it
/// serves). Public traffic is the coordinator's, from its parity qualification.
/// A runtime capability, such as a claimed `mlx_nax`, is not an input to that
/// decision.
public enum DistributedServingEligibility {
    /// The hardware part of what a control-only member reports
    /// (`memberRegistrationCapabilities`): the detector's answer with no bound
    /// runtime and no kernel probe. It opens no pair.
    public static func memberCapabilities(chipFamily: ChipFamily) -> Set<ProviderRuntimeCapability> {
        ProviderRuntimeCapabilityDetector.detect(chipFamily: chipFamily, naxAvailable: { false }, liveMetallibHash: { nil })
    }

    /// What a member registers and attests: its hardware capabilities and
    /// `cache_policy_v1`, since a pair runs a `memory_only` request with its
    /// ranks' prefix cache off. The coordinator sends such a request to a
    /// pair only when every member reports it.
    public static func memberRegistrationCapabilities(chipFamily: ChipFamily) -> Set<ProviderRuntimeCapability> {
        memberCapabilities(chipFamily: chipFamily)
    }
}
