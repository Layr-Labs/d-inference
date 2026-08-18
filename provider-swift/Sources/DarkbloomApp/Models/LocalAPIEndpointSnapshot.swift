import Foundation

enum LocalAPIMode: String, CaseIterable, Sendable {
    /// One provider process serves network and same-machine requests through the
    /// same loaded models, scheduler, and memory budget.
    case unified

    /// A coordinator-free foreground server started with `darkbloom start --local`.
    case directOnly = "direct-only"

    var startCommand: String {
        switch self {
        case .unified:
            "darkbloom start --local-endpoint"
        case .directOnly:
            "darkbloom start --local"
        }
    }
}

enum LocalAPIBindScope: String, Sendable {
    case thisMac = "this-mac"
    case network
    case allInterfaces = "all-interfaces"

    init(host: String) {
        let normalized = host.lowercased()
        switch normalized {
        case "localhost", "::1":
            self = .thisMac
        case "0.0.0.0", "::", "":
            self = .allInterfaces
        default:
            self = normalized.hasPrefix("127.") ? .thisMac : .network
        }
    }
}

enum LocalAPIHealth: Equatable, Sendable {
    case checking
    case reachable
    case unreachable
}

enum LocalAPIModelCatalog: Equatable, Sendable {
    case loading
    case available([String])
    case failed
}

/// UI-facing local endpoint state. Discovery supplies the connection fields;
/// health, mode, and available models require separate runtime probes and stay
/// optional/sample-only until those services are connected.
///
/// Deliberately not Codable: API keys must never enter app persistence.
struct LocalAPIEndpointSnapshot: Equatable, Sendable {
    var baseURL: URL
    var host: String
    var port: UInt16
    var apiKey: String?
    var pid: Int32
    var version: String
    var updatedAt: Date
    var mode: LocalAPIMode?
    var health: LocalAPIHealth
    var modelCatalog: LocalAPIModelCatalog

    var requiresAuthentication: Bool {
        apiKey?.isEmpty == false
    }

    var bindScope: LocalAPIBindScope {
        LocalAPIBindScope(host: host)
    }

    var availableModelIDs: [String]? {
        guard case .available(let modelIDs) = modelCatalog else { return nil }
        return modelIDs
    }

    var isOpenWithoutAuthentication: Bool {
        !requiresAuthentication
    }
}

enum LocalAPIState: Equatable, Sendable {
    case starting(message: String)
    case running(LocalAPIEndpointSnapshot)
    case stopped(message: String)
    case unavailable(message: String)
}

enum LocalAPIFixture: String, CaseIterable, Sendable {
    case active
    case directOnly = "direct-only"
    case starting
    case stopped
    case authDisabled = "auth-disabled"
    case networkExposed = "network-exposed"
    case noCompatibleModels = "no-compatible-models"
    case modelCatalogUnavailable = "model-catalog-unavailable"
    case healthChecking = "health-checking"
    case portCollision = "port-collision"
    case tokenUnavailable = "token-unavailable"
    case unreachable
}

enum LocalAPICodeExample: String, CaseIterable, Identifiable, Sendable {
    case curl
    case python

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curl: "cURL"
        case .python: "Python"
        }
    }
}

enum LocalAPICopyItem: Equatable, Sendable {
    case baseURL
    case apiKey
    case code(LocalAPICodeExample)
    case command(LocalAPIMode)

    var confirmation: String {
        switch self {
        case .baseURL: "Copied base URL"
        case .apiKey: "Copied API key"
        case .code(let example): "Copied \(example.title) example"
        case .command(let mode): "Copied \(mode == .unified ? "Local + network" : "Local only") command"
        }
    }
}
