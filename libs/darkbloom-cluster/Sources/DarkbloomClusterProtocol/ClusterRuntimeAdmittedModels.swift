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
    /// Every model a capability may name, in declaration order. Read from the
    /// adapters themselves, so a model added to an adapter appears here
    /// without a second list to keep in step.
    public static var admittedModels: [ClusterAdmittedModel] {
        allCases.map {
            ClusterAdmittedModel(adapterID: $0.rawValue, adapterVersion: $0.version,
                runtimeModelID: $0.runtimeModelID, profileID: $0.profileID)
        }
    }
}
