/// Endpoint discovery is evidence of a connection, never of process ownership.
/// Only the shared local-start controller can offer an End session action.
struct ProviderMenuBarLocalPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let tone: MenuBarStatusTone
    let isSample: Bool
    let showsEndSession: Bool
    let canEndSession: Bool
    let isBusy: Bool

    init(
        state: LocalAPIState,
        startState: LocalAPIStartState,
        hasActiveSession: Bool,
        isLive: Bool
    ) {
        isSample = !isLive
        showsEndSession = isLive && hasActiveSession
        canEndSession = showsEndSession && startState != .cancelling
        isBusy = isLive && hasActiveSession && (startState.isWaiting || startState == .cancelling)

        let status = hasActiveSession && isLive
            ? Self.ownedSession(startState, endpointState: state)
            : Self.discoveredEndpoint(state, startState: startState)
        title = status.0
        detail = isLive ? status.1 : "Sample status only. This preview runs no local AI."
        tone = isLive ? status.2 : .neutral
    }

    private static func ownedSession(
        _ state: LocalAPIStartState,
        endpointState: LocalAPIState
    ) -> (String, String, MenuBarStatusTone) {
        switch state {
        case .starting, .waitingForEndpoint:
            return ("Starting local session", "Started by this app. Waiting for the model’s endpoint.", .neutral)
        case .ready(let modelID):
            guard case .running(let endpoint) = endpointState,
                  endpoint.health == .reachable,
                  endpoint.availableModelIDs?.contains(modelID) == true
            else {
                return ("Checking local session", "This app owns the session; its endpoint needs a check.", .neutral)
            }
            return ("Local session ready", "Started by this app for your chats and API.", .active)
        case .cancelling:
            return ("Ending local session", "Waiting for this app’s local process to stop.", .neutral)
        case .failed(.shutdownTimedOut):
            return ("Session has not stopped", "Keep Darkbloom open. The app hasn’t confirmed shutdown.", .attention)
        case .failed:
            return ("Session needs attention", "This app still owns the session. Check Studio or end it here.", .attention)
        case .idle, .cancelled:
            return ("Local session open", "This app owns the session; readiness is not confirmed.", .neutral)
        }
    }

    private static func discoveredEndpoint(
        _ state: LocalAPIState,
        startState: LocalAPIStartState
    ) -> (String, String, MenuBarStatusTone) {
        switch state {
        case .running(let endpoint):
            switch endpoint.health {
            case .checking:
                return ("Checking existing endpoint", "Managed outside Studio, possibly by the network provider.", .neutral)
            case .unreachable:
                return ("Endpoint not responding", "Managed outside Studio. Open Studio to check the connection.", .attention)
            case .reachable:
                switch endpoint.modelCatalog {
                case .available(let models) where models.isEmpty:
                    return ("No models advertised", "The endpoint responds but lists no models. Managed outside Studio.", .attention)
                case .available:
                    return ("Endpoint responding", "Managed outside Studio, possibly by the network provider.", .active)
                case .loading:
                    return ("Checking endpoint models", "The endpoint responds. Managed outside Studio.", .neutral)
                case .failed:
                    return ("Model list unavailable", "The endpoint responds. Check its models in Studio; it is managed externally.", .attention)
                }
            }
        case .starting:
            return ("Checking local endpoint", "No app-owned session. Open Studio to check the connection.", .neutral)
        case .stopped:
            if case .failed = startState {
                return ("Local start needs attention", "No app-owned session. Open Studio to check the last start.", .attention)
            }
            return ("Local AI not connected", "Open Studio to choose a model on this Mac.", .neutral)
        case .unavailable:
            return ("Local status unavailable", "Open Studio to check the local connection.", .attention)
        }
    }
}
