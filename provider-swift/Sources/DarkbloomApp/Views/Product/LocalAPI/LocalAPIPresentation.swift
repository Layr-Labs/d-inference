import Foundation

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

    static func authenticationDetail(requiresAuthentication: Bool) -> String {
        requiresAuthentication
            ? "Send the bearer token with every inference request. The sample key stays hidden until you reveal it."
            : "Any process that can reach this address can make inference requests. Enable authentication before exposing it."
    }
}
