/// Runtime failures use the normal failure exit code. ArgumentParser's
/// ValidationError is reserved for invalid user arguments, not peer failures.
enum DistributedStartRuntimeError: Error, CustomStringConvertible, CaseIterable {
    case listenerStopped, cleanupUnresolved, sessionFailed, memberControlEnded

    var description: String {
        switch self {
        case .listenerStopped: return "Distributed listener stopped during startup."
        case .cleanupUnresolved: return "Distributed cleanup is unresolved; the cluster remains unavailable."
        case .sessionFailed: return "Distributed serving stopped after a runtime failure."
        case .memberControlEnded: return "Distributed serving stopped because the coordinator control connection ended or lost trust (reason above); restart once the coordinator is reachable."
        }
    }
}
