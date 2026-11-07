import Darwin
import Foundation
import ProviderCore

extension IntegrationTool {
    /// The tool's name in the lines `start` prints.
    var displayName: String {
        switch self {
        case .opencode: "OpenCode"
        case .hermes: "Hermes"
        }
    }

    /// The executable's name on `PATH`.
    var executableName: String { rawValue }

    /// The start flag that sets this tool up.
    var flag: String { "--\(rawValue)" }
}

/// Whether a tool is on this Mac, as `start --opencode` / `--hermes` looks for it.
enum ToolInstall: Equatable, Sendable {
    case installed(URL)
    case missing
    /// OpenCode 1, which reads another config format.
    case tooOld(version: String)
}

/// Finds OpenCode and Hermes the way Ollama does: on `PATH`, else where their installers put them. Never installs
/// anything.
enum ToolLocator {
    static func find(_ tool: IntegrationTool, path: String?, home: URL,
                     version: (URL) -> String? = { _ in nil }) -> ToolInstall { .missing }

    static func majorVersion(_ text: String) -> Int? { nil }
}

/// Red skeleton: `start --opencode` / `--hermes` parse, but set nothing up and say nothing.
struct ToolIntegrationStep {
    var tools: [IntegrationTool]
    var environment: ToolIntegrationEnvironment = .current
    var provider: IntegrationProvider = .current
    var findTool: (IntegrationTool) -> ToolInstall
    var fetchModels: (IntegrationEndpoint) async throws -> [EndpointModel]
    var fetchCatalog: () async -> CatalogSnapshot?
    var say: (String) -> Void

    static func live(tools: [IntegrationTool], coordinatorURL: String) -> ToolIntegrationStep {
        ToolIntegrationStep(tools: tools, findTool: { _ in .missing }, fetchModels: { _ in [] },
                            fetchCatalog: { nil }, say: { _ in })
    }

    func run(endpoint: IntegrationEndpoint, requests: String) async -> Bool { false }

    static func noLocalAPI(_ tools: [IntegrationTool]) -> String { "" }

    static func notUp(_ tools: [IntegrationTool], seconds: Int) -> String { "" }

    static func noPairAPI(_ tools: [IntegrationTool]) -> String { "" }

    static func names(_ tools: [IntegrationTool]) -> String { "" }
}
