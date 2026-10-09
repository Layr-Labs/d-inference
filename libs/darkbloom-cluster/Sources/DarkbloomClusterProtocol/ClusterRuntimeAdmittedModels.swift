import Foundation

/// One model this protocol revision accepts in a runtime capability, named as
/// the capability names it. A listing for operators: admission itself is
/// `ClusterRuntimeCapabilityValidation`.
public struct ClusterAdmittedModel: Equatable, Sendable {
    public let adapterID: String
    public let adapterVersion: Int
    public let runtimeModelID: String
    public let profileID: String
}

extension ClusterRuntimeAdapter {
    /// Every model a capability may name: each adapter's registered pairs, in
    /// declaration order. Read from the list admission itself checks, so a
    /// model registered there appears here without a second list to keep in step.
    public static var admittedModels: [ClusterAdmittedModel] {
        allCases.flatMap { adapter in
            adapter.registeredProfiles.map {
                ClusterAdmittedModel(adapterID: adapter.rawValue, adapterVersion: adapter.version,
                    runtimeModelID: $0.runtimeModelID, profileID: $0.profileID)
            }
        }
    }
}
