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

/// Whether a tool is on this Mac, as `darkbloom --opencode` / `--hermes` looks for it.
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

/// `darkbloom --opencode` / `--hermes`: once, at start, points each tool at this Mac's live local API, with a
/// backup and a one-line undo. It first waits while the API's process still loads this Mac's models (`ModelLoadWait`),
/// so the tools get each model's own limits. It never prints or writes a key, and a tool it can't set up never stops
/// Darkbloom serving.
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
    /// The wait, before anything is written, while the local API's process still loads this Mac's models; nil: none.
    var modelLoadWait: ModelLoadWait?

    /// How long the step waits for the local API's `/v1/models`. That list waits for the coordinator's up to the
    /// router's own deadline (`LocalRouter.Timing.list`), so with an unreachable coordinator it answers late: the step
    /// gives it well over that, once, at start.
    static let modelListTimeout: TimeInterval = 15

    /// The step as `start` runs it: the tools found on this Mac, the endpoint's models, the coordinator's catalog, and
    /// the wait for this Mac's models to load.
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
            versionOutput: { _, executable in ToolLocator.version(of: executable) },
            modelLoadWait: .live())
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
                    + "`\(Self.command([tool]))` again.")
                failed = true
            case .tooOld:
                say("✗ OpenCode 1 is installed; Darkbloom sets up OpenCode 2. Run `opencode upgrade`, then "
                    + "`\(Self.command([.opencode]))` again.")
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
        let tools = ready.map(\.tool)
        guard let read = await readModels(endpoint, tools: tools) else { return false }
        let catalog = await fetchCatalog()
        // No tool's config is written while the local API's process still loads a model this Mac lists for its start:
        // a wait that ends before it is loaded (the deadline, a model that didn't load, Ctrl-C) returns here, before
        // any file is touched.
        guard let afterWait = await waitForModels(read, endpoint: endpoint, tools: tools, catalog: catalog) else {
            return false
        }
        let listed = afterWait.listed
        let models = IntegrationModels.resolve(listed, catalog: catalog,
                                               here: endpoint.servesThePair ? .yourPair : .thisMac)
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
                : Self.catalogUnreachable(tools))
        }
        let unloaded = Self.notLoaded(listed, loaded: afterWait.loaded)
        if !unloaded.isEmpty {
            say(Self.runAgainOnceLoaded(unloaded.map { IntegrationModels.displayName(of: $0.id, in: catalog) },
                                        tools: tools))
        }
        let keyFile = ToolIntegration.displayPath(endpoint.keyFile, home: environment.home)
        say("  Requests: \(requests)")
        say("  Other tools: OPENAI_BASE_URL=\(endpoint.baseURL) OPENAI_API_KEY=\"$(cat \(keyFile))\"")
        return ok
    }

    /// The endpoint's models; nil, said in one line, when they can't be read.
    private func readModels(_ endpoint: IntegrationEndpoint, tools: [IntegrationTool]) async -> [EndpointModel]? {
        do {
            return try await fetchModels(endpoint)
        } catch {
            say("✗ Couldn't read the models of this Mac's local API (\(Self.describe(error))), so "
                + "\(Self.notSetUp(tools)).")
            return nil
        }
    }

    /// This Mac's models the tools got no limits of this Mac's for: those its process hasn't `loaded`, by its own word.
    /// Without that word, those listed without a context, which this Mac lists only while a model is loaded (unless its
    /// router fills the catalog's in, with an account key and a route that dials out).
    static func notLoaded(_ listed: [EndpointModel], loaded: Set<String>?) -> [EndpointModel] {
        let thisMac = listed.filter { IntegrationModels.location(ownedBy: $0.ownedBy) == .thisMac }
        guard let loaded else { return thisMac.filter { $0.contextLength == nil } }
        return thisMac.filter { !loaded.contains($0.id) }
    }

    /// Waits (`modelLoadWait`; none without it) while the local API's process still loads this Mac's models in
    /// `listed`, then gives what the endpoint lists now, their own limits included, and what the process has loaded
    /// by its own word (nil without it); nil, said in one line, when nothing may be written: the model didn't load,
    /// is still loading at the deadline, or Ctrl-C stopped the wait, even as it ended.
    private func waitForModels(_ listed: [EndpointModel], endpoint: IntegrationEndpoint, tools: [IntegrationTool],
                               catalog: CatalogSnapshot?) async -> (listed: [EndpointModel], loaded: Set<String>?)? {
        guard let wait = modelLoadWait else { return (listed, nil) }
        let thisMac = listed.filter { IntegrationModels.location(ownedBy: $0.ownedBy) == .thisMac }.map(\.id)
        let name = { (id: String) in IntegrationModels.displayName(of: id, in: catalog) }
        switch await wait.run(thisMac: thisMac, tools: tools, name: name, say: say) {
        case .ready(let waited, let loaded):
            // Ctrl-C after the wait's last look, as it ended: still nothing is written. Past the wait, Ctrl-C does
            // what it did before it.
            guard !wait.interrupt.wasPressed else {
                say(ModelLoadWait.stoppedBeforeWriting(tools))
                return nil
            }
            guard waited else { return (listed, loaded) }
            return await readModels(endpoint, tools: tools).map { ($0, loaded) }
        case .notLoaded(let model):
            say(ModelLoadWait.didNotLoad(name(model), tools: tools))
        case .timedOut(let model):
            say(ModelLoadWait.stillLoading(name(model), tools: tools, after: wait.timeout))
        case .interrupted(let model):
            say(ModelLoadWait.stopped(name(model), tools: tools))
        }
        return nil
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
            var lines = ["✓ \(tool.displayName) can use Darkbloom: \(count(summary.models.count)).",
                         "  Changed: \(ToolIntegration.displayPath(file, home: home)) "
                            + "(\(changed(tool, summary, newFile: backup == nil, provider: provider)))"]
            if let backup { lines.append("  Backup:  \(ToolIntegration.displayPath(backup, home: home))") }
            switch tool {
            case .opencode:
                lines += ["  " + openCodeDefault(summary, models: models, provider: provider,
                                                 file: ToolIntegration.displayPath(file, home: home)),
                          "  Undo:    \(undo)"]
            case .hermes:
                let main = summary.defaultModel.map { "Darkbloom's \(name(of: $0, in: models))" } ?? "Darkbloom"
                let before = summary.replacedDefault.map { " (before: \($0))" } ?? ""
                lines += ["  New Hermes chats now use \(main)\(before). Switch back: hermes model",
                          "  Undo:    \(undo)   ·   Chats already open keep their model."]
                if !summary.leftOut.isEmpty {
                    lines.append("  Left out: \(summary.leftOut.joined(separator: ", ")) (Hermes needs 64K context)")
                }
            }
            if let note = summary.droppedCommentsNote { lines.append("  Note:    \(note)") }
            return (lines, true)
        }
    }

    /// What a written config now holds of Darkbloom's, for the `Changed:` line: the provider, and the default model
    /// when the edit set it. Hermes always makes Darkbloom its main model.
    static func changed(_ tool: IntegrationTool, _ summary: ToolConfigSummary, newFile: Bool,
                        provider: IntegrationProvider) -> String {
        let block = "the \"\(provider.id)\" provider"
        switch tool {
        case .opencode:
            let andDefault = summary.defaultModel == nil ? "" : " and the default model"
            if newFile { return "a new file with \(block)\(andDefault)" }
            switch summary.provider {
            case .added: return "added \(block)\(andDefault); nothing else changed"
            case .updated: return "updated \(block)\(andDefault); nothing else changed"
            case .unchanged: return "added the default model; nothing else changed"
            }
        case .hermes:
            if newFile { return "a new file with \(block) as the main model" }
            switch summary.provider {
            case .added: return "added \(block) and made it the main model"
            case .updated: return "updated \(block) and made it the main model"
            case .unchanged: return "made \(block) the main model"
            }
        }
    }

    /// OpenCode's default model after a written edit, on its own line: Darkbloom's when OpenCode had none, with the way
    /// back that lasts (`/models` doesn't: a config's `model` comes first at every launch), `file` being the edited
    /// one; else the default that stays, or the pick OpenCode remembers from `/models`, which Darkbloom's can be too.
    static func openCodeDefault(_ summary: ToolConfigSummary, models: [IntegrationModel],
                                provider: IntegrationProvider, file: String) -> String {
        let ours = provider.id + "/"
        if let set = summary.defaultModel {
            let id = set.hasPrefix(ours) ? String(set.dropFirst(ours.count)) : set
            return "New OpenCode sessions now use Darkbloom's \(name(of: id, in: models)). To go back, remove \"model\" "
                + "from \(file) or run the Undo below."
        }
        if let kept = summary.keptDefault {
            return kept.hasPrefix(ours) ? "Your default stays \(kept) (the \"model\" in your OpenCode config)."
                : "Your default stays \(kept); pick Darkbloom with /models."
        }
        if summary.rememberedPick != nil { return "Pick Darkbloom once with /models; OpenCode remembers it." }
        return "Your default model stays as your config sets it; pick Darkbloom with /models."
    }

    /// A model's name without where it runs (`Qwen 3.8 27B`), else its ID.
    static func name(of id: String, in models: [IntegrationModel]) -> String {
        models.first { $0.id == id }.map { IntegrationModel.displayName(in: $0.name) } ?? id
    }

    /// The line beside a local API that already serves as the start would: the address the tools reach it at, never
    /// the address it listens on (`0.0.0.0` for a pair's).
    static func alreadyServes(_ live: LocalEndpoint.Info, tools: [IntegrationTool]) -> String {
        "Darkbloom already serves at \(live.baseURL); setting up \(names(tools)) for it."
    }

    /// The line when this start has no local API for the tools.
    static func noLocalAPI(_ tools: [IntegrationTool]) -> String {
        "This Mac serves only the Darkbloom network, so \(names(tools)) \(tools.count == 1 ? "has" : "have") no local "
            + "address to use. Choose \"Both, me first\" (`\(command(tools)) --me-first`) or \"Only me\" "
            + "(`\(command(tools)) --local`)."
    }

    /// The line for this Mac's models that were neither loaded nor loading as the tools were set up (unloaded when
    /// idle, or loaded only on a request), so the tools got no limits of this Mac's for them.
    static func runAgainOnceLoaded(_ models: [String], tools: [IntegrationTool]) -> String {
        "  Run `\(command(tools))` again once `\(cli) status` shows \(ModelLoadWait.list(models)) loaded, to pick up "
            + "\(models.count == 1 ? "its" : "their") limits."
    }

    /// The line when the local API didn't come up in time after a background start.
    static func notUp(_ tools: [IntegrationTool], seconds: Int) -> String {
        "✗ This Mac's local API didn't answer within \(seconds) seconds, so \(notSetUp(tools)). Run "
            + "`\(command(tools))` again once `\(cli) local` shows it."
    }

    /// The line on a paired Mac whose pair serves only the Darkbloom network: no Mac of it has a local API.
    static func noPairAPI(_ tools: [IntegrationTool]) -> String {
        "✗ This pair serves only the Darkbloom network, so \(names(tools)) \(tools.count == 1 ? "has" : "have") no "
            + "local address to use and \(tools.count == 1 ? "wasn't" : "weren't") set up. In `\(cli) cluster`, Change "
            + "how the pair serves to \"Both, me first\" or \"Only me\", then run `\(command(tools))` again."
    }

    /// The line on a Mac whose pair keeps its local API on the Mac that runs it, on `bind` only: no other Mac passes
    /// its port on.
    static func pairAPIElsewhere(_ tools: [IntegrationTool], bind: String) -> String {
        "✗ The pair's local API listens on the Mac that runs it only (\(bind)), so \(notSetUp(tools)) on this Mac: run "
            + "`\(command(tools))` on that Mac."
    }

    /// The line on a Mac of a pair that has no working address for the pair now, said at once: its `status` line's
    /// words (`localAPI`, after "Local API: ").
    static func noMemberAddress(_ tools: [IntegrationTool], localAPI: String) -> String {
        "✗ \(notSetUp(tools)) on this Mac. Local API: \(localAPI)\(localAPI.hasSuffix(".") ? "" : ".") Run "
            + "`\(command(tools))` again once this Mac answers."
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
        "  Darkbloom's catalog wasn't reachable: run `\(command(tools))` again online for the models' "
            + "names and image support."
    }

    /// The last line when a tool couldn't be set up: the start never stops Darkbloom for a tool.
    static let keepsServing = "Darkbloom keeps serving."

    static var cli: String { BuildEnvironment.current.cliName }

    static func names(_ tools: [IntegrationTool]) -> String { tools.map(\.displayName).joined(separator: " and ") }

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
