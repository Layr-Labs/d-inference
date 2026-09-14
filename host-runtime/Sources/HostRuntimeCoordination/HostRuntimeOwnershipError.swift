import Foundation

public enum HostRuntimeOwnershipError: Error, Equatable, CustomStringConvertible {
    case authorityMissing
    case insecureAuthority
    case occupied
    case authorityChanged
    case maintenancePending
    case invalidMaintenanceIntent
    case maintenanceChanged
    case maintenanceFinished
    case rootMaintenanceRequired
    case systemError(Int32)

    public var description: String {
        switch self {
        case .authorityMissing: "machine runtime ownership has not been provisioned"
        case .insecureAuthority: "machine runtime ownership has unsafe permissions or identity"
        case .occupied: "another runtime owns this machine"
        case .authorityChanged: "machine runtime ownership authority was replaced"
        case .maintenancePending: "offline maintenance remains pending; root recovery must prove cleanup before workloads resume"
        case .invalidMaintenanceIntent: "offline maintenance intent is invalid"
        case .maintenanceChanged: "offline maintenance authority changed or does not match this operation"
        case .maintenanceFinished: "offline maintenance scope has already finished"
        case .rootMaintenanceRequired: "offline maintenance requires the root operator"
        case .systemError(let code): "machine runtime ownership failed with errno \(code)"
        }
    }
}
