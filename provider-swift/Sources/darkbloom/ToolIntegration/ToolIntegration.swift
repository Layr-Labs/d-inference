import Darwin
import Foundation
import ProviderCore

/// The agent tools Darkbloom sets up to use it as a provider (`darkbloom --opencode` / `--hermes`).
enum IntegrationTool: String, CaseIterable, Sendable {
    case opencode
    case hermes

    /// The user config this tool reads, chosen as the tool itself chooses it.
    func configFile(in environment: ToolIntegrationEnvironment) -> URL {
        switch self {
        case .opencode: OpenCodeConfigPlan.configFile(home: environment.home, variables: environment.variables)
        case .hermes: HermesConfigPlan.configFile(home: environment.home, variables: environment.variables)
        }
    }

    /// The mode of a config file Darkbloom creates; an existing file keeps its own. A Hermes config can hold other
    /// providers' keys, so it starts owner-only.
    var newFileMode: mode_t {
        switch self {
        case .opencode: 0o644
        case .hermes: 0o600
        }
    }

    func plan(
        existing: Data?, file: URL, endpoint: IntegrationEndpoint, models: [IntegrationModel],
        provider: IntegrationProvider, home: URL
    ) -> ToolConfigPlan {
        switch self {
        case .opencode:
            OpenCodeConfigPlan.plan(existing: existing, fileName: file.lastPathComponent, endpoint: endpoint,
                                    models: models, provider: provider, home: home,
                                    defaultModelElsewhere: OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: file))
        case .hermes:
            HermesConfigPlan.plan(existing: existing, endpoint: endpoint, models: models, provider: provider)
        }
    }
}

/// Darkbloom as the tools name it. Each build identity has its own, so a test build beside the production one adds a
/// second provider instead of overwriting the first.
struct IntegrationProvider: Equatable, Sendable {
    /// The provider's key in the tools' configs, which is also the CLI's name (`darkbloom`, `darkbloom-dev`).
    let id: String
    let name: String

    static var current: IntegrationProvider {
        IntegrationProvider(id: BuildEnvironment.current.cliName, name: BuildEnvironment.current.appDisplayName)
    }
}

/// Where a tool sends its requests: Darkbloom's local endpoint, and the file that holds its key. It carries the key
/// file's path, never the key, so no planner can write the key into a tool's config: the tools read it from the file.
struct IntegrationEndpoint: Equatable, Sendable {
    /// `http://<host>:<port>/v1`, as `local.json` names the live server.
    let baseURL: String
    let keyFile: URL

    /// The live local server `info`, by default the one in `local.json` (its own port, never an assumed one), with the
    /// key file for that port; nil when no server runs, it serves without a key, or no key file holds its key.
    static func live(_ info: LocalEndpoint.Info? = LocalEndpoint.readLiveInfo(),
                     keyFile: (UInt16) -> URL? = { LocalEndpoint.keyFile(forPort: Int($0)) }) -> IntegrationEndpoint? {
        guard let info, !info.apiKey.isEmpty, let file = keyFile(info.port) else { return nil }
        return IntegrationEndpoint(baseURL: info.baseURL, keyFile: file)
    }
}

/// The home, environment variables and Darkbloom state directory an integration runs against; tests use temp ones.
struct ToolIntegrationEnvironment: Sendable {
    let home: URL
    let variables: [String: String]
    /// `<install dir>/integrations`: the lock and the backups. Darkbloom never writes them into a tool's directory.
    let stateDirectory: URL

    init(home: URL, variables: [String: String], stateDirectory: URL? = nil) {
        self.home = home
        self.variables = variables
        self.stateDirectory = stateDirectory
            ?? BuildEnvironment.current.installDirectory(home: home).appendingPathComponent("integrations")
    }

    static var current: ToolIntegrationEnvironment {
        ToolIntegrationEnvironment(home: FileManager.default.homeDirectoryForCurrentUser,
                                   variables: ProcessInfo.processInfo.environment)
    }
}

/// What the start flags call for each tool: finds the tool's config, plans the edit and makes it safely.
enum ToolIntegration {
    /// Points `tool` at `endpoint` with `models`. A dry run plans and writes nothing: no backup, no lock, no file.
    static func configure(
        _ tool: IntegrationTool, endpoint: IntegrationEndpoint, models: [IntegrationModel],
        provider: IntegrationProvider = .current, environment: ToolIntegrationEnvironment = .current,
        dryRun: Bool = false
    ) throws -> ToolConfigWriter.Outcome {
        let file = tool.configFile(in: environment)
        let writer = ToolConfigWriter(tool: tool, stateDirectory: environment.stateDirectory)
        return try writer.apply(to: file, newFileMode: tool.newFileMode, dryRun: dryRun) { existing in
            tool.plan(existing: existing, file: file, endpoint: endpoint, models: models, provider: provider,
                      home: environment.home)
        }
    }

    /// `~/…` for a path under `home`, else the absolute path: for the lines `start` prints.
    static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// `word` as one POSIX shell word in single quotes; with `onlyIfNeeded`, bare when it has no special character.
    static func shellQuoted(_ word: String, onlyIfNeeded: Bool = false) -> String {
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+=:,@%")
        if onlyIfNeeded, !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
