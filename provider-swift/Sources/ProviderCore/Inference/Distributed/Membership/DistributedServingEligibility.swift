import Foundation

/// The provider's model eligibility gate as it applies to a distributed start.
///
/// The gate itself is `ModelRuntimeRequirements` and is not changed here. A
/// cluster member reports only what it can state without running a model: its
/// chip class. It never reports a kernel capability such as `mlx_nax`, which
/// would need a GPU probe the control-only member does not make. A model whose
/// requirements include one is therefore refused for every pair, and this
/// type says so after the gate's own sentence.
public enum DistributedServingEligibility {
    /// What a control-only member reports about itself: the detector's answer
    /// with no bound runtime and no kernel probe.
    public static func memberCapabilities(chipFamily: ChipFamily) -> Set<ProviderRuntimeCapability> {
        ProviderRuntimeCapabilityDetector.detect(chipFamily: chipFamily, naxAvailable: { false }, liveMetallibHash: { nil })
    }

    public static func require(modelID: String, memberCapabilities: Set<ProviderRuntimeCapability>) throws {
        let eligibility = ModelRuntimeRequirements.evaluate(modelID: modelID, available: memberCapabilities)
        guard eligibility.isEligible else { throw DistributedServingIneligibleError(eligibility: eligibility) }
    }
}

public struct DistributedServingIneligibleError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    public let eligibility: ModelRuntimeEligibility

    public var errorDescription: String? { description }
    public var description: String {
        (ModelRuntimeIneligibleError(eligibility: eligibility).errorDescription ?? "Model '\(eligibility.modelID)' is ineligible")
            + ". A cluster member reports its chip class only and never a kernel capability, so a model that requires one is refused for every pair. "
            + "That is a policy decision about this model, not a fault in the cluster setup, and no cluster setting changes it."
    }
}
