import Foundation

enum LocalAPIEndpointPhase {
    case starting
    case stopped
    case unavailable
}

enum LocalAPIPresentation {
    static func modeTitle(_ mode: LocalAPIMode?) -> String {
        switch mode {
        case .unified:
            "Local + network"
        case .directOnly:
            "Local only"
        case nil:
            "Mode not reported"
        }
    }

    static func modeDetail(_ mode: LocalAPIMode?) -> String {
        switch mode {
        case .unified:
            "The local API and private network share this provider’s model scheduler and memory budget."
        case .directOnly:
            "A coordinator-free server handles requests sent directly to this Mac."
        case nil:
            "Local discovery does not identify how the endpoint was started."
        }
    }

    static func accessTitle(_ scope: LocalAPIBindScope) -> String {
        switch scope {
        case .thisMac:
            "Only this Mac"
        case .network:
            "Specific network address"
        case .allInterfaces:
            "All network interfaces"
        }
    }

    static func accessDetail(_ scope: LocalAPIBindScope) -> String {
        switch scope {
        case .thisMac:
            "Bound to loopback. Other devices cannot connect to this address."
        case .network:
            "Reachable through one configured network address. The endpoint uses HTTP, not built-in TLS."
        case .allInterfaces:
            "Reachable through every active interface over HTTP, without built-in TLS. Keep API-key authentication on and use only trusted networks."
        }
    }

    static func availableModelSummary(_ catalog: LocalAPIModelCatalog) -> String {
        switch catalog {
        case .loading:
            "Checking…"
        case .failed:
            "Unavailable"
        case .available(let modelIDs):
            switch modelIDs.count {
            case 0:
                "None"
            case 1:
                "1 model"
            default:
                "\(modelIDs.count) models"
            }
        }
    }

    static func availableModelDetail(_ catalog: LocalAPIModelCatalog) -> String {
        switch catalog {
        case .loading:
            "Darkbloom is checking the endpoint’s advertised model catalog."
        case .failed:
            "The endpoint did not return its available-model catalog."
        case .available(let modelIDs) where modelIDs.isEmpty:
            "Download a supported GPT-OSS or Gemma 4 model before sending requests."
        case .available(let modelIDs):
            modelIDs.joined(separator: " · ")
        }
    }

    static func authenticationTitle(requiresAuthentication: Bool) -> String {
        requiresAuthentication ? "API key required" : "Authentication disabled"
    }

    static func authenticationDetail(
        requiresAuthentication: Bool,
        isLive: Bool = false
    ) -> String {
        requiresAuthentication
            ? "Send the bearer token with every inference request. The \(isLive ? "API key" : "sample key") stays hidden until you reveal it."
            : "Any process that can reach this address can make inference requests. Enable authentication before exposing it."
    }

    static func stateTitle(_ phase: LocalAPIEndpointPhase, isLive: Bool) -> String {
        let endpoint = isLive ? "endpoint" : "sample endpoint"
        switch phase {
        case .starting: "\(isLive ? "Endpoint" : "Sample endpoint") is starting"
        case .stopped: "No \(endpoint) is running"
        case .unavailable: "The \(endpoint) needs attention"
        }
    }

    static func healthTitle(_ endpoint: LocalAPIEndpointSnapshot, isLive: Bool) -> String {
        let noun = isLive ? "Endpoint" : "Sample endpoint"
        switch endpoint.health {
        case .checking: "Checking \(noun.lowercased())"
        case .reachable where endpoint.isOpenWithoutAuthentication:
            "\(noun) open"
        case .reachable:
            "\(noun) ready"
        case .unreachable:
            "\(noun) unavailable"
        }
    }

    static func modeLabel(_ mode: LocalAPIMode?, isLive: Bool) -> String {
        isLive || mode == nil ? "Mode" : "Sample mode"
    }

    static func apiKeyLabel(isLive: Bool) -> String {
        isLive ? "API key" : "Sample API key"
    }

    static func credentialsDetail(isLive: Bool) -> String {
        if isLive {
            return "Darkbloom reads this credential from the provider’s owner-only local discovery record. Keep it secret and rotate it by restarting the local endpoint."
        }
        return "The provider stores its local token with owner-only file permissions. This preview uses a fixture and never reads that file."
    }
}
