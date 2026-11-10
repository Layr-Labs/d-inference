import Foundation

/// Whether the coordinator sends public requests to a pair offered through Darkbloom, by the coordinator's own rule
/// (darkbloom-platform `cluster_public_routing.go`, `cluster_parity_qualification.go`): a session serves requests of any
/// account only under a promotable parity qualification of its approval and mode family. Qualifications attach only to
/// a build-pinned cluster approval, and a release derives them only for the models it declares public
/// (`ClusterPublicModels.declared`, in their declared families). A model approval, or a pair approval saved by hand,
/// serves its owner's own requests only, so a pair under one is paired and runs but answers 429 `cluster_not_public`
/// to every public request (DevNet Gemma pair, 2026-11-05). Each part writes the reason to its log, and the screens and
/// status show it instead of ✓.
public enum ClusterPublicServingCheck {
    /// Why the coordinator serves only this account's own requests from a pair offered under `clusterApproval` (or a
    /// pair approval saved by hand, `handSaved`) in mode `family`; nil when it may serve the public.
    public static func ownerOnlyReason(clusterApproval: ClusterRuntimeApproval?, handSaved: Bool,
                                       family: ClusterPairServingModeFamily,
                                       declared: [ClusterPublicModel] = ClusterPublicModels.declared) -> String? {
        typealias Words = ClusterOnboardingNotServing
        guard let approval = clusterApproval else {
            return handSaved ? Words.notPublicPrefix + "it runs under a pair approval saved by hand" + Words.notPublicModelApproval + ")" : nil
        }
        if approval.isModelApproval {
            return Words.notPublicPrefix + "it runs under the model approval \(approval.id)" + Words.notPublicModelApproval + ")"
        }
        guard let model = declared.first(where: { $0.catalogModelID == approval.model }) else {
            return Words.notPublicPrefix + approval.model + Words.notPublicModel + ")"
        }
        if model.families.contains(family) { return nil }
        let names = model.families.map(\.description)
        let families = names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return Words.notPublicPrefix + approval.model + Words.notPublicFamilies + families + " only)"
    }

    /// `notice` when it is such a reason in plain text, else nil.
    public static func ownerOnly(notice: String?) -> String? {
        guard let notice, notice.hasPrefix(ClusterOnboardingNotServing.notPublicPrefix), notice.hasSuffix(")"), notice.count <= 400,
              !notice.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
        else { return nil }
        return notice
    }
}
