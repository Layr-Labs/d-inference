import Foundation
import ProviderCore

/// What a tool's own config says of Darkbloom, for `darkbloom doctor`'s Local API section: the file the tool reads (as
/// `darkbloom --opencode` / `--hermes` choose it) and where Darkbloom's provider block there points, read as `start`'s
/// notice reads it (`ToolAddress.readPointer`). Read only. Of the key only the file it is read from is kept, never a
/// key written into the config, so no line can show it.
struct DoctorToolSetup: Equatable, Sendable {
    enum Found: Equatable, Sendable {
        /// No config, or no Darkbloom provider block in it.
        case notSetUp
        /// Darkbloom's provider block: where it sends requests, and the file it reads the key from.
        case entry(ToolPointer)
        /// The file can't be read as the tool's config, and why.
        case unreadable(String)
    }

    let tool: IntegrationTool
    let file: URL
    let found: Found

    /// Each tool's config in `environment`, as the tool chooses it.
    static func read(_ environment: ToolIntegrationEnvironment = .current,
                     provider: IntegrationProvider = .current) -> [DoctorToolSetup] {
        IntegrationTool.allCases.map { tool in
            DoctorToolSetup(tool: tool, file: tool.configFile(in: environment),
                            found: Self.found(tool, environment: environment, provider: provider))
        }
    }

    private static func found(_ tool: IntegrationTool, environment: ToolIntegrationEnvironment,
                              provider: IntegrationProvider) -> Found {
        do {
            let pointer = try ToolAddress.readPointer(of: tool, environment: environment, provider: provider)
            return pointer.map(Found.entry) ?? .notSetUp
        } catch {
            return .unreadable(error.reason)
        }
    }
}
