import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// Tensor parallel is offered for a model only once it has loaded on real Macs. A rule about the model, never the
/// hardware: MiMo V2.6's tensor parallel was offered and recommended on two M5 Ultras (0.10.9 DevNet) and never became
/// ready, as it never had anywhere, while its pipeline has served. Its tensor-parallel modes leave the plan's modes
/// before anything is ranked, so no speed, record or kept mode brings them back; a developer's forced mode still places
/// them, which is how the proof is made. The capability records and their digests are unchanged.
public enum ClusterTensorParallelProof {
    /// Runtime models whose tensor parallel has not loaded on two real Macs.
    public static let notLoadedOnRealMacs: Set<String> = ["registered_mimo_v26_flash_mopd"]

    /// Why the plan leaves the model's tensor parallel out (`ClusterPlacementPolicy.modesReason`).
    public static let reason = "tensor parallel isn't offered for this model yet: it hasn't loaded on real Macs"

    /// Leaves `layout`'s tensor-parallel modes out of `policy` for a model in `notLoadedOnRealMacs`, unless a developer
    /// forced the mode. Whether it did.
    @discardableResult
    static func apply(to policy: inout ClusterPlacementPolicy, layout: ClusterModelLayout, forced: Bool,
                      notLoaded: Set<String> = notLoadedOnRealMacs) -> Bool {
        guard !forced, notLoaded.contains(layout.runtimeModelID),
              layout.generationModes.contains(where: \.usesTensorParallelDecode) else { return false }
        policy.modes = (policy.modes ?? layout.generationModes).filter { !$0.usesTensorParallelDecode }
        policy.modesReason = policy.modesReason ?? reason
        return true
    }
}
