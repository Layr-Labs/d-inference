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
    /// The first executable named `tool` on `path`, else in the tool's own install folder under `home`.
    static func find(_ tool: IntegrationTool, path: String?, home: URL,
                     version: (URL) -> String? = { ToolLocator.version(of: $0) }) -> ToolInstall {
        let folders = (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let fallbacks: [URL] = switch tool {
        case .opencode: [home.appendingPathComponent(".opencode/bin", isDirectory: true)]
        case .hermes: [home.appendingPathComponent(".local/bin", isDirectory: true)]
        }
        guard let executable = (folders + fallbacks).map({ $0.appendingPathComponent(tool.executableName) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return .missing }
        if tool == .opencode, let text = version(executable), let major = majorVersion(text), major < 2 {
            return .tooOld(version: text)
        }
        return .installed(executable)
    }

    /// The major version in `opencode --version`'s answer (`opencode v2.2.0`, `2.2.0`); nil when there is none.
    static func majorVersion(_ text: String) -> Int? {
        guard let range = text.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range].split(separator: ".")[0])
    }

    /// `<executable> --version`'s first line, waiting at most `seconds`; nil when it doesn't answer.
    static func version(of executable: URL, seconds: Double = 5) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data.prefix(4_096), as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

/// `darkbloom start --opencode` / `--hermes`: once, at start, points each tool at this Mac's live local API, with a
/// backup and a one-line undo. It never prints or writes a key, and a tool it can't set up never stops Darkbloom
/// serving.
struct ToolIntegrationStep {
    var tools: [IntegrationTool]
    var environment: ToolIntegrationEnvironment = .current
    var provider: IntegrationProvider = .current
    var findTool: (IntegrationTool) -> ToolInstall
    var fetchModels: (IntegrationEndpoint) async throws -> [EndpointModel]
    /// The Darkbloom catalog's names and limits; nil when it can't be reached.
    var fetchCatalog: () async -> CatalogSnapshot?
    var say: (String) -> Void
    /// `<tool> --version`'s first line; nil when it doesn't answer.
    var versionOutput: (IntegrationTool, URL) -> String? = { _, _ in nil }
    /// The wait before anything is written. Skeleton: unused.
    var modelLoadWait: ModelLoadWait?

    /// How long the step waits for the local API's `/v1/models`. That list waits for the coordinator's up to the
    /// router's own deadline (`LocalRouter.Timing.list`), so with an unreachable coordinator it answers late: the step
    /// gives it well over that, once, at start.
    static let modelListTimeout: TimeInterval = 15

    /// The step as `start` runs it: the tools found on this Mac, the endpoint's models and the coordinator's catalog.
    static func live(tools: [IntegrationTool], coordinatorURL: String) -> ToolIntegrationStep {
        let environment = ToolIntegrationEnvironment.current
        return ToolIntegrationStep(
            tools: tools, environment: environment,
            findTool: { ToolLocator.find($0, path: environment.variables["PATH"], home: environment.home) },
            fetchModels: { try await IntegrationModels.fetch($0, timeout: Self.modelListTimeout) },
            fetchCatalog: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 5
                configuration.timeoutIntervalForResource = 5
                let client = ModelCatalogClient(coordinatorURL: coordinatorURL,
                                                urlSession: URLSession(configuration: configuration))
                return try? await client.fetchCatalogSnapshot(includeAliases: true)
            },
            say: { print($0) },
            versionOutput: { _, executable in ToolLocator.version(of: executable) })
    }

    /// Sets each tool up for `endpoint`. `requests` says where the owner's requests go, in the start screen's words.
    /// Returns whether every tool is set up now (changed, or already set up).
    func run(endpoint: IntegrationEndpoint, requests: String) async -> Bool {
        var ready: [(tool: IntegrationTool, executable: URL)] = []
        var failed = false
        for tool in tools {
            switch findTool(tool) {
            case .installed(let executable):
                ready.append((tool, executable))
            case .missing:
                say("✗ \(tool.displayName) isn't installed on this Mac. Install it, then run "
                    + "`\(Self.cli) start \(tool.flag)` again.")
                failed = true
            case .tooOld:
                say("✗ OpenCode 1 is installed; Darkbloom sets up OpenCode 2. Run `opencode upgrade`, then "
                    + "`\(Self.cli) start --opencode` again.")
                failed = true
            }
        }
        if !ready.isEmpty {
            failed = await configure(ready, endpoint: endpoint, requests: requests) == false || failed
        }
        if failed { say(Self.keepsServing) }
        return !failed
    }

    private func configure(_ ready: [(tool: IntegrationTool, executable: URL)], endpoint: IntegrationEndpoint,
                           requests: String) async -> Bool {
        let listed: [EndpointModel]
        do {
            listed = try await fetchModels(endpoint)
        } catch {
            say("✗ Couldn't read the models of this Mac's local API (\(Self.describe(error))), so "
                + "\(Self.notSetUp(ready.map(\.tool))).")
            return false
        }
        let catalog = await fetchCatalog()
        let models = IntegrationModels.resolve(listed, catalog: catalog)
        var ok = true
        var summaries: [ToolConfigSummary] = []
        for (tool, executable) in ready {
            let outcome: ToolConfigWriter.Outcome
            do {
                outcome = try ToolIntegration.configure(tool, endpoint: endpoint, models: models, provider: provider,
                                                        environment: environment)
            } catch {
                say("✗ Couldn't set up \(tool.displayName): \(error).")
                ok = false
                continue
            }
            let (lines, done) = Self.lines(tool, outcome, models: models, provider: provider,
                                           home: environment.home)
            lines.forEach(say)
            ok = ok && done
            if let summary = outcome.summary { summaries.append(summary) }
            // An older Hermes can't read the key yet: set up anyway, and say how to fix it.
            if tool == .hermes, done, let warning = versionOutput(tool, executable)
                .flatMap({ HermesVersion.keyCommandWarning(versionOutput: $0) }) {
                say("  Warning: \(warning)")
            }
        }
        if catalog == nil, !summaries.isEmpty {
            say(summaries.allSatisfy(\.undescribed.isEmpty) ? Self.catalogUnreachableKept
                : Self.catalogUnreachable(ready.map(\.tool)))
        }
        // This Mac lists a model's context only while it is loaded, so the tools got the catalog's limits for the rest.
        let unloaded = listed.filter {
            $0.contextLength == nil && IntegrationModels.location(ownedBy: $0.ownedBy) == .thisMac
        }
        if !unloaded.isEmpty {
            say(Self.runAgainOnceLoaded(unloaded.map(\.id), tools: ready.map(\.tool)))
        }
        let keyFile = ToolIntegration.displayPath(endpoint.keyFile, home: environment.home)
        say("  Requests: \(requests)")
        say("  Other tools: OPENAI_BASE_URL=\(endpoint.baseURL) OPENAI_API_KEY=\"$(cat \(keyFile))\"")
        return ok
    }

    /// The lines for one tool's outcome, and whether the tool is set up. Never a key.
    static func lines(_ tool: IntegrationTool, _ outcome: ToolConfigWriter.Outcome, models: [IntegrationModel],
                      provider: IntegrationProvider, home: URL) -> (lines: [String], done: Bool) {
        switch outcome {
        case .unchanged(_, let summary), .planned(_, _, let summary):
            return (tool == .opencode
                ? ["✓ OpenCode already lists Darkbloom's \(count(summary.models.count)) (nothing changed)."]
                : ["✓ Hermes already uses Darkbloom's current models (nothing changed)."], true)
        case .refused(let file, let refusal):
            return (["✗ " + refusal.message(file: ToolIntegration.displayPath(file, home: home))], false)
        case .written(let file, let backup, let undo, let summary):
            let path = ToolIntegration.displayPath(file, home: home)
            let what = summary.provider == .updated ? "updated" : "added"
            var lines: [String]
            switch tool {
            case .opencode:
                let changed = backup == nil ? "a new file with the \"\(provider.id)\" provider"
                    : "\(what) the \"\(provider.id)\" provider; nothing else changed"
                let useIt = summary.defaultModel.map { "in OpenCode, /models → \(provider.name); new sessions use \($0)." }
                    ?? "in OpenCode, /models → \(provider.name). Your default model is unchanged."
                lines = ["✓ OpenCode can use Darkbloom: \(count(summary.models.count)).",
                         "  Changed: \(path) (\(changed))"]
                if let backup { lines.append("  Backup:  \(ToolIntegration.displayPath(backup, home: home))") }
                lines += ["  Use it:  \(useIt)", "  Undo:    \(undo)"]
            case .hermes:
                let model = summary.defaultModel.flatMap { id in models.first { $0.id == id }?.name ?? id }
                lines = ["✓ Hermes uses Darkbloom: new Hermes chats run \(model ?? "a Darkbloom model")."]
                lines.append("  Changed: \(path) (\(backup == nil ? "a new file with" : what) the \"\(provider.id)\" "
                    + "provider, made the main model)")
                if let backup { lines.append("  Backup:  \(ToolIntegration.displayPath(backup, home: home))") }
                lines.append("  Switch back: hermes model   ·   Undo: \(undo)   ·   Chats already open keep their model.")
                if !summary.leftOut.isEmpty {
                    lines.append("  Left out: \(summary.leftOut.joined(separator: ", ")) (Hermes needs 64K context)")
                }
            }
            if let note = summary.droppedCommentsNote { lines.append("  Note:    \(note)") }
            return (lines, true)
        }
    }

    /// The line when this start has no local API for the tools.
    static func noLocalAPI(_ tools: [IntegrationTool]) -> String {
        "This Mac serves only the Darkbloom network, so \(names(tools)) \(tools.count == 1 ? "has" : "have") no local "
            + "address to use. Choose \"Both, me first\" (`\(cli) start --me-first \(flags(tools))`) or \"Only me\" "
            + "(`\(cli) start --local \(flags(tools))`)."
    }

    /// The line for this Mac's models that weren't loaded as the tools were set up. Skeleton: today's words.
    static func runAgainOnceLoaded(_ models: [String], tools: [IntegrationTool]) -> String {
        let one = models.count == 1
        return "  Run `\(cli) start \(flags(tools))` again once the \(one ? "model is" : "models are") loaded, to pick "
            + "up \(one ? "its" : "their") limits."
    }

    /// The line when the local API didn't come up in time after a background start.
    static func notUp(_ tools: [IntegrationTool], seconds: Int) -> String {
        "✗ This Mac's local API didn't answer within \(seconds) seconds, so \(notSetUp(tools)). Run "
            + "`\(cli) start \(flags(tools))` again once `\(cli) local` shows it."
    }

    /// The line on a paired Mac whose pair has no local API on this Mac.
    static func noPairAPI(_ tools: [IntegrationTool]) -> String {
        "✗ This Mac has no local API for the pair, so \(notSetUp(tools)). `\(cli) cluster local` serves the pair on "
            + "the leading Mac's own API; run this there."
    }

    /// The line beside a running local API without a key (`--no-auth`), which tools can't use.
    static func keyless(port: UInt16) -> String {
        "✗ Darkbloom's local API on :\(port) has no key (--no-auth); tools need one: start it without --no-auth."
    }

    /// The line when a background start's local API answers, but no key file holds its key.
    static func noKeyFile(_ tools: [IntegrationTool], port: UInt16) -> String {
        "✗ This Mac's local API on :\(port) answers, but no key file holds its key, so \(notSetUp(tools))."
    }

    /// The line when the catalog can't be read and the tools' own entries kept every model's name and image support.
    static let catalogUnreachableKept = "  Darkbloom's catalog wasn't reachable, so the models' names and image "
        + "support stay as they were."

    /// The line when the catalog can't be read and a tool now lists a model without its name and image support.
    static func catalogUnreachable(_ tools: [IntegrationTool]) -> String {
        "  Darkbloom's catalog wasn't reachable: run `\(cli) start \(flags(tools))` again online for the models' "
            + "names and image support."
    }

    /// The last line when a tool couldn't be set up: the start never stops Darkbloom for a tool.
    static let keepsServing = "Darkbloom keeps serving."

    static var cli: String { BuildEnvironment.current.cliName }

    static func names(_ tools: [IntegrationTool]) -> String { tools.map(\.displayName).joined(separator: " and ") }

    static func flags(_ tools: [IntegrationTool]) -> String { tools.map(\.flag).joined(separator: " ") }

    /// The command that sets `tools` up: `darkbloom --opencode --hermes`, short for `darkbloom start --opencode
    /// --hermes` (`Darkbloom.expandingToolShortcuts`).
    static func command(_ tools: [IntegrationTool]) -> String { ([cli] + tools.map(\.flag)).joined(separator: " ") }

    /// "OpenCode wasn't set up", "OpenCode and Hermes weren't set up".
    static func notSetUp(_ tools: [IntegrationTool]) -> String {
        "\(names(tools)) \(tools.count == 1 ? "wasn't" : "weren't") set up"
    }

    static func count(_ models: Int) -> String { models == 1 ? "1 model" : "\(models) models" }

    /// An error in plain words, without anything a server sent back.
    static func describe(_ error: Error) -> String {
        switch error {
        case IntegrationModelsError.keyUnreadable: "its key file can't be read"
        case IntegrationModelsError.badURL: "its address isn't valid"
        case IntegrationModelsError.http(let status): "HTTP \(status)"
        case IntegrationModelsError.undecodable: "its answer isn't a model list"
        default: "it didn't answer"
        }
    }
}
