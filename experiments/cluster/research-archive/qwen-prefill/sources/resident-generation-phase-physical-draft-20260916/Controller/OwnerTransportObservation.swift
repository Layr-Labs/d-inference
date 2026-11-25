import Foundation
import DarkbloomClusterProcess

func qualificationOwnerTermination(_ value: ClusterWorkerProcessTermination?) -> [String: Any] {
    switch value {
    case .none: return ["kind": "unobserved"]
    case .launchFailed?: return ["kind": "launchFailed"]
    case .exited(let status)?: return ["kind": "exited", "status": status]
    case .signalled(let signal)?: return ["kind": "signalled", "signal": signal]
    }
}
