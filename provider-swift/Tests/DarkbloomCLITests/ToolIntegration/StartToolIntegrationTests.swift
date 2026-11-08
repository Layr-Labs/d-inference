import ArgumentParser
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import ProviderCore
@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// A temp home with Darkbloom's key file, and a recorder for what the step says. No tool runs, no port is bound, and
/// no real home, OpenCode or Hermes config is read or written.
private final class StepSandbox: @unchecked Sendable {
    let directory: TemporaryDirectory
    let token = F.freshToken()
    let home: URL
    let keyFile: URL
    var said: [String] = []

    init() throws {
        directory = try TemporaryDirectory("start-tools")
        home = directory.file("home")
        keyFile = try directory.write(token, to: "home/.darkbloom/local_token", mode: 0o600)
    }

    var endpoint: IntegrationEndpoint { IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile) }

    /// 128K context, which both tools can use, and 32K, which Hermes can't.
    static let listed = [
        EndpointModel(id: "qwen3.8-27b", ownedBy: "this-mac", contextLength: 131_072),
        EndpointModel(id: "gemma-4-26b-qat-4bit", ownedBy: "this-mac", contextLength: 32_768),
    ]

    func step(_ tools: [IntegrationTool], installed: Set<IntegrationTool> = Set(IntegrationTool.allCases),
              listed: [EndpointModel]? = StepSandbox.listed, catalog: CatalogSnapshot? = nil,
              hermesVersion: String? = nil) -> ToolIntegrationStep {
        ToolIntegrationStep(
            tools: tools, environment: ToolIntegrationEnvironment(home: home, variables: [:]), provider: F.provider,
            findTool: { installed.contains($0) ? .installed(URL(fileURLWithPath: "/fake/\($0.rawValue)")) : .missing },
            fetchModels: { _ in
                guard let listed else { throw IntegrationModelsError.http(status: 503) }
                return listed
            },
            fetchCatalog: { catalog },
            say: { self.said.append($0) },
            versionOutput: { tool, _ in tool == .hermes ? hermesVersion : nil })
    }

    /// The catalog's names and capabilities for `listed`, and a smaller output cap for Qwen.
    static let catalog = CatalogSnapshot(models: [
        CatalogModel(id: "qwen3.8-27b", s3Name: "qwen3.8-27b", displayName: "Qwen 3.8 27B", sizeGb: 1,
                     maxContextLength: 262_144, maxOutputLength: 8_192, capabilities: ["tools", "vision", "reasoning"]),
        CatalogModel(id: "gemma-4-26b-qat-4bit", s3Name: "gemma-4-26b-qat-4bit", displayName: "Gemma 4 26B", sizeGb: 1,
                     maxContextLength: 262_144, capabilities: ["tools", "vision"]),
    ], aliases: [])

    var openCodeFile: URL { home.appendingPathComponent(".config/opencode/opencode.jsonc") }
    var hermesFile: URL { home.appendingPathComponent(".hermes/config.yaml") }

    /// Every file but the key file.
    func filesOtherThanTheKey() -> [URL] {
        directory.allFiles().filter { $0.resolvingSymlinksInPath().path != keyFile.resolvingSymlinksInPath().path }
    }
}

@Suite("Start: --opencode and --hermes", .serialized)
struct StartToolIntegrationTests {
    // MARK: - Flags

    @Test("--opencode and --hermes parse alone and together, and are not single-Mac options")
    func flagsParse() throws {
        #expect(try Start.parse(["--opencode"]).requestedTools == [.opencode])
        #expect(try Start.parse(["--hermes"]).requestedTools == [.hermes])
        #expect(try Start.parse(["--hermes", "--opencode"]).requestedTools == [.opencode, .hermes])
        #expect(try Start.parse([]).requestedTools.isEmpty)
        #expect(try Start.parse(["--opencode", "--hermes"]).singleMacOptions.isEmpty)
        for arguments in [["--opencode", "--local"], ["--opencode", "--me-first"], ["--hermes", "--local-endpoint",
                          "--port", "8123"], ["--opencode", "--hermes", "--route", "my-macs"], ["--opencode", "--choose"]] {
            _ = try Start.parse(arguments)
        }
    }

    static let refused: [([String], String)] = [
        (["--opencode", "--network"],
         "`--opencode` needs this Mac's local API, which `--network` doesn't serve. Use --me-first or --local instead."),
        (["--hermes", "--local-endpoint", "--no-auth"],
         "`--hermes` points Hermes at a local API that needs its key; with `--no-auth` anything on this Mac could use it. Drop --no-auth."),
        (["--opencode", "--cluster-member"],
         "`--opencode` sets a tool up beside a local API; a --cluster-member start serves none."),
        (["--opencode", "--foreground"],
         "`--opencode` runs once, at `darkbloom start`; the --foreground service never sets tools up."),
        (["--opencode", "--local", "--distributed"],
         "`--opencode` doesn't start a cluster. Start it first, then run `darkbloom --opencode` on its own: it "
            + "sets OpenCode up for the cluster's local API."),
    ]

    @Test("they are refused with --network, --no-auth, a cluster member, --distributed and the --foreground service",
          arguments: StartToolIntegrationTests.refused)
    func refusals(arguments: [String], message: String) {
        do {
            _ = try Start.parse(arguments)
            Issue.record("\(arguments) must be refused")
        } catch {
            #expect(Start.message(for: error) == message)
        }
    }

    @Test("a start that would serve no local API refuses the tools before anything starts or is saved")
    func noLocalAPIRefused() throws {
        let directory = try TemporaryDirectory("start-tools-config")
        let config = try directory.write("[provider]\nname = \"d2b\"\n", to: "provider.toml")
        let before = try Data(contentsOf: config)
        let refusal = "This Mac serves only the Darkbloom network, so OpenCode and Hermes have no local address to "
            + "use. Choose \"Both, me first\" (`darkbloom --opencode --hermes --me-first`) or \"Only me\" "
            + "(`darkbloom --opencode --hermes --local`). Nothing was started or saved."
        for (terminal, answers) in [(false, [String]()), (true, ["2"])] {
            var remaining = answers
            let start = try Start.parse(["--opencode", "--hermes", "--config", config.path])
            do {
                _ = try start.resolveServing(environment: ServingEnvironment(
                    terminal: terminal, readInput: { remaining.isEmpty ? nil : remaining.removeFirst() },
                    emit: { _ in }, accountKeySaved: { false }, ownLivePort: { nil }, installedPort: { nil },
                    isFree: { _ in true }))
                Issue.record("no local API must refuse the tools")
            } catch let error as ValidationError {
                #expect(error.message == refusal)
            }
        }
        #expect(try Data(contentsOf: config) == before)
        #expect(ToolIntegrationStep.noLocalAPI([.opencode]).hasSuffix("(`darkbloom --opencode --local`)."))
    }

    // MARK: - Already serving: set the tools up, start nothing

    @Test("a running local API is used as it is unless an option changes what serves or the address differs")
    func runningLocalAPIShortcut() throws {
        let keyFile = URL(fileURLWithPath: "/tmp/fixture/local_token")
        let live = LocalEndpoint.Info(host: "127.0.0.1", port: 8123, apiKey: "dk-local-fixture", version: "test",
                                      pid: 1, updatedAt: "")
        func shortcut(_ arguments: [String], _ info: LocalEndpoint.Info? = live,
                      keyFile file: URL? = keyFile) throws -> IntegrationEndpoint? {
            try Start.parse(arguments).runningLocalAPI(info, keyFile: { _ in file })
        }
        let expected = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)
        for arguments in [["--opencode"], ["--hermes", "--local"], ["--opencode", "--me-first"],
                          ["--opencode", "--port", "8123"], ["--opencode", "--bind", "127.0.0.1"]] {
            #expect(try shortcut(arguments) == expected, "\(arguments)")
        }
        for arguments in [["--opencode", "--model", "fixture/model"], ["--opencode", "--all"],
                          ["--opencode", "--idle-timeout", "5"], ["--opencode", "--port", "9000"],
                          ["--opencode", "--bind", "0.0.0.0"], ["--opencode", "--route", "my-macs"],
                          ["--opencode", "--no-me-first"], ["--opencode", "--me-first-idle", "5"],
                          ["--opencode", "--choose"], ["--opencode", "--coordinator-url", "ws://127.0.0.1:1/ws/provider"],
                          ["--local"], []] {
            #expect(try shortcut(arguments) == nil, "\(arguments)")
        }
        #expect(try shortcut(["--opencode"], nil) == nil)
        #expect(try shortcut(["--opencode"], LocalEndpoint.Info(host: "127.0.0.1", port: 8123, apiKey: "",
                                                                 version: "test", pid: 1, updatedAt: "")) == nil)
        #expect(try shortcut(["--opencode"], keyFile: nil) == nil)
    }

    @Test("a background start waits for its own local API, bounded")
    func waitsForTheLocalAPI() async throws {
        let keyFile = URL(fileURLWithPath: "/tmp/fixture/local_token")
        var answers: [LocalEndpoint.Info?] = [nil, LocalEndpoint.Info(host: "127.0.0.1", port: 9000, apiKey: "k",
                                                                      version: "", pid: 1, updatedAt: ""),
                                              LocalEndpoint.Info(host: "0.0.0.0", port: 8123, apiKey: "k",
                                                                 version: "", pid: 1, updatedAt: "")]
        let found = await Start.waitForLocalAPI(port: 8123, seconds: 30,
                                                live: { answers.isEmpty ? nil : answers.removeFirst() },
                                                keyFile: { _ in keyFile }, pause: {})
        #expect(found == .ready(IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)))
        let none = await Start.waitForLocalAPI(port: 8123, seconds: 0, live: { nil }, keyFile: { _ in keyFile },
                                               pause: {})
        #expect(none == .notUp)
        // Its own port with a key that no key file holds: said at once, not after the wait.
        var pauses = 0
        let keyless = await Start.waitForLocalAPI(port: 8123, seconds: 30,
                                                  live: { LocalEndpoint.Info(host: "127.0.0.1", port: 8123, apiKey: "k",
                                                                             version: "", pid: 1, updatedAt: "") },
                                                  keyFile: { _ in nil }, pause: { pauses += 1 })
        #expect(keyless == .noKeyFile && pauses == 0)
        #expect(ToolIntegrationStep.notUp([.opencode], seconds: 30) == "✗ This Mac's local API didn't answer within 30 "
            + "seconds, so OpenCode wasn't set up. Run `darkbloom --opencode` again once `darkbloom local` shows it.")
    }

    @Test("beside a running local API without a key (--no-auth), the start names it and starts nothing")
    func keylessRunningAPIIsNamed() async throws {
        let keyless = LocalEndpoint.Info(host: "127.0.0.1", port: 8123, apiKey: "", version: "test", pid: 1,
                                         updatedAt: "")
        await #expect(throws: ExitCode.failure) {
            _ = try await Start.parse(["--opencode"]).setUpToolsForRunningLocalAPI(live: keyless)
        }
        #expect(ToolIntegrationStep.keyless(port: 8123) == "✗ Darkbloom's local API on :8123 has no key (--no-auth); "
            + "tools need one: start it without --no-auth.")
        // An option that changes what serves, another port, or no tool flag: the start runs, as before.
        for arguments in [["--opencode", "--model", "fixture/model"], ["--opencode", "--port", "9000"], []] {
            #expect(try await Start.parse(arguments).setUpToolsForRunningLocalAPI(live: keyless) == false,
                    "\(arguments)")
        }
    }

    @Test("after a background start the tool step runs; a failed step, no key file or no API exits 1")
    func toolStepAfterABackgroundStart() async throws {
        let start = try Start.parse(["--opencode"])
        let serving = StartServing(mode: .both, source: .saved, meFirst: true, meFirstIdleMinutes: 2,
                                   route: .myMacsFirst, accountKeySaved: true, port: 8123, bind: "127.0.0.1",
                                   noAuth: false)
        let coordinator = "wss://coordinator.invalid/ws/provider"
        let sandbox = try StepSandbox()
        try await start.setUpToolsBesideDaemon(serving: serving, coordinatorURL: coordinator,
                                               waitForAPI: { _ in .ready(sandbox.endpoint) },
                                               step: sandbox.step([.opencode]))
        #expect(FileManager.default.fileExists(atPath: sandbox.openCodeFile.path), "the step ran")
        // The tool block says where requests go from the key this start read, without reading it again.
        #expect(sandbox.said.contains("  Requests: this Mac first, then your other Macs (free), then the Darkbloom "
            + "network (billed)"))
        let missing = try StepSandbox()
        await #expect(throws: ExitCode.failure) {
            try await start.setUpToolsBesideDaemon(serving: serving, coordinatorURL: coordinator,
                                                   waitForAPI: { _ in .ready(missing.endpoint) },
                                                   step: missing.step([.opencode], installed: []))
        }
        #expect(missing.said.last == "Darkbloom keeps serving.")
        for wait in [Start.LocalAPIWait.noKeyFile, .notUp] {
            let untouched = try StepSandbox()
            await #expect(throws: ExitCode.failure) {
                try await start.setUpToolsBesideDaemon(serving: serving, coordinatorURL: coordinator,
                                                       waitForAPI: { _ in wait }, step: untouched.step([.opencode]))
            }
            #expect(untouched.said.isEmpty && untouched.filesOtherThanTheKey().isEmpty, "\(wait)")
        }
        #expect(ToolIntegrationStep.noKeyFile([.opencode], port: 8123) == "✗ This Mac's local API on :8123 answers, "
            + "but no key file holds its key, so OpenCode wasn't set up.")
    }

    @Test("start --local --opencode reads the account key once, for the banner and the tool block; no key shown")
    func localWithAToolReadsTheAccountKeyOnce() throws {
        let directory = try TemporaryDirectory("start-tools-local")
        let config = try directory.write("[provider]\nname = \"d2b\"\n\n[local]\nroute = \"my-macs-first\"\n",
                                         to: "provider.toml")
        var lookups = 0
        let environment = ServingEnvironment(terminal: false, readInput: { nil }, emit: { _ in },
                                             accountKeySaved: { lookups += 1; return true }, ownLivePort: { nil },
                                             installedPort: { nil }, isFree: { _ in true })
        let start = try Start.parse(["--local", "--opencode", "--config", config.path])
        let serving = try #require(try start.resolveServing(environment: environment))
        #expect(serving.mode == .local && serving.accountKeySaved == true && lookups == 1)
        // The banner's words come from that one read: requests can leave this Mac, so it doesn't say "this Mac only".
        #expect(LocalFirstWords.requests(route: serving.route, accountKeySaved: serving.accountKeySaved ?? false)
            == "this Mac first, then your other Macs (free), then the Darkbloom network (billed)")
        #expect(!start.bannerShowsKey(serving), "no key in the banner with a tool flag")
        // `--local` alone keeps its banner, key included, and still never asks the Keychain.
        let plain = try Start.parse(["--local", "--config", config.path])
        let plainServing = try #require(try plain.resolveServing(environment: environment))
        #expect(plain.bannerShowsKey(plainServing) && plainServing.accountKeySaved == nil && lookups == 1)
    }

    /// The local API's `/v1/models` waits for the coordinator's lists up to the router's own deadline
    /// (`LocalRouter.Timing.list`), so with a black-holed coordinator it answers late; the step's read must outlast it.
    @Test("the step's model read waits out a slow /v1/models, longer than D2a's 5 s")
    func modelReadWaitsOutASlowList() async throws {
        let directory = try TemporaryDirectory("start-tools-slow")
        let keyFile = try directory.write(F.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
        let router = Router()
        router.get("/v1/models") { _, _ -> Response in
            try await Task.sleep(for: .seconds(6))
            let list = #"{"object":"list","data":[{"id":"slow","object":"model","owned_by":"this-mac"}]}"#
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: list)))
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await app.test(.live) { client in
            let port = try #require(client.port)
            // `localhost`: the live test server may listen on either loopback address.
            let endpoint = IntegrationEndpoint(baseURL: "http://localhost:\(port)/v1", keyFile: keyFile)
            let step = ToolIntegrationStep.live(tools: [.opencode],
                                                coordinatorURL: "wss://coordinator.invalid/ws/provider")
            #expect(try await step.fetchModels(endpoint).map(\.id) == ["slow"])
        }
        #expect(ToolIntegrationStep.modelListTimeout > Double(LocalRouter.Timing().list.components.seconds) * 2,
                "well over the router's own list deadline")
    }

    @Test("a model this Mac hasn't loaded yet gets one line: run the start again once it is loaded")
    func unloadedModelsSayRunAgain() async throws {
        let line = "  Run `darkbloom --opencode` again once `darkbloom status` shows gpt-oss-120b loaded, to pick up "
            + "its limits."
        let sandbox = try StepSandbox()
        let unloaded = StepSandbox.listed + [EndpointModel(id: "gpt-oss-120b", ownedBy: "this-mac")]
        #expect(await sandbox.step([.opencode], listed: unloaded).run(endpoint: sandbox.endpoint, requests: "x"))
        #expect(sandbox.said.filter { $0 == line }.count == 1)
        // Loaded models, and another Mac's model without a context (not this Mac's to load), get no such line.
        for listed in [StepSandbox.listed, StepSandbox.listed + [EndpointModel(id: "other", ownedBy: "my-macs")]] {
            let quiet = try StepSandbox()
            _ = await quiet.step([.opencode], listed: listed).run(endpoint: quiet.endpoint, requests: "x")
            #expect(!quiet.said.contains { $0.hasPrefix("  Run `") })
        }
        #expect(ToolIntegrationStep.runAgainOnceLoaded(["Gemma 4 26B", "Qwen 3.8 27B"], tools: [.opencode, .hermes])
            == "  Run `darkbloom --opencode --hermes` again once `darkbloom status` shows Gemma 4 26B and Qwen 3.8 27B "
            + "loaded, to pick up their limits.")
    }

    // MARK: - Finding the tools

    @Test("the tools are found on PATH or where their installers put them; OpenCode 1 is too old")
    func toolLocator() throws {
        let directory = try TemporaryDirectory("start-tools-path")
        let home = directory.file("home")
        let bin = try directory.write("#!/bin/sh\n", to: "bin/opencode", mode: 0o755)
        let notExecutable = try directory.write("", to: "other/hermes", mode: 0o644)
        let path = [bin.deletingLastPathComponent().path, notExecutable.deletingLastPathComponent().path]
            .joined(separator: ":")
        func found(_ install: ToolInstall) -> String? {
            if case .installed(let executable) = install { return executable.path }
            return nil
        }
        #expect(found(ToolLocator.find(.opencode, path: path, home: home, version: { _ in "opencode v2.2.0" }))
            == bin.path)
        #expect(ToolLocator.find(.opencode, path: path, home: home, version: { _ in "1.9.4" })
            == .tooOld(version: "1.9.4"))
        #expect(found(ToolLocator.find(.opencode, path: path, home: home, version: { _ in nil })) == bin.path)
        #expect(ToolLocator.find(.hermes, path: path, home: home) == .missing)
        let installed = try directory.write("#!/bin/sh\n", to: "home/.opencode/bin/opencode", mode: 0o755)
        #expect(found(ToolLocator.find(.opencode, path: nil, home: home, version: { _ in nil })) == installed.path)
        let hermes = try directory.write("#!/bin/sh\n", to: "home/.local/bin/hermes", mode: 0o755)
        #expect(found(ToolLocator.find(.hermes, path: "", home: home)) == hermes.path)
        #expect(ToolLocator.majorVersion("opencode v2.2.0") == 2)
        #expect(ToolLocator.majorVersion("1.0.12") == 1)
        #expect(ToolLocator.majorVersion("dev") == nil)
    }

    // MARK: - The step: lines, files, no key

    @Test("both tools are set up with the file, the backup and a one-line undo, and no key anywhere")
    func setsBothToolsUp() async throws {
        let sandbox = try StepSandbox()
        let ok = await sandbox.step([.opencode, .hermes]).run(endpoint: sandbox.endpoint, requests: "this Mac only")
        #expect(ok)
        #expect(sandbox.said == [
            "✓ OpenCode can use Darkbloom: 2 models.",
            "  Changed: ~/.config/opencode/opencode.jsonc (a new file with the \"darkbloom\" provider)",
            "  Use it:  in OpenCode, /models → Darkbloom; new sessions use darkbloom/gemma-4-26b-qat-4bit.",
            "  Undo:    rm \(ToolIntegration.shellQuoted(sandbox.openCodeFile.path))",
            "✓ Hermes uses Darkbloom: new Hermes chats run qwen3.8-27b (this Mac).",
            "  Changed: ~/.hermes/config.yaml (a new file with the \"darkbloom\" provider, made the main model)",
            "  Switch back: hermes model   ·   Undo: rm \(ToolIntegration.shellQuoted(sandbox.hermesFile.path))   ·   "
                + "Chats already open keep their model.",
            "  Left out: gemma-4-26b-qat-4bit (Hermes needs 64K context)",
            "  Darkbloom's catalog wasn't reachable: run `darkbloom --opencode --hermes` again online for the "
                + "models' names and image support.",
            "  Requests: this Mac only",
            "  Other tools: OPENAI_BASE_URL=http://127.0.0.1:8123/v1 OPENAI_API_KEY=\"$(cat ~/.darkbloom/local_token)\"",
        ])

        // Again: nothing changes, and no backup is made.
        sandbox.said = []
        #expect(await sandbox.step([.opencode, .hermes]).run(endpoint: sandbox.endpoint, requests: "this Mac only"))
        #expect(Array(sandbox.said.prefix(2)) == [
            "✓ OpenCode already lists Darkbloom's 2 models (nothing changed).",
            "✓ Hermes already uses Darkbloom's current models (nothing changed).",
        ])

        // A changed list updates the provider, with a backup and the undo that restores it.
        sandbox.said = []
        let fewer = sandbox.step([.opencode], listed: [StepSandbox.listed[0]])
        #expect(await fewer.run(endpoint: sandbox.endpoint, requests: "this Mac only"))
        let backups = sandbox.home.appendingPathComponent(".darkbloom/integrations/backups/opencode")
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        let backup = backups.appendingPathComponent(name)
        #expect(Array(sandbox.said.prefix(5)) == [
            "✓ OpenCode can use Darkbloom: 1 model.",
            "  Changed: ~/.config/opencode/opencode.jsonc (updated the \"darkbloom\" provider; nothing else changed)",
            "  Backup:  ~/.darkbloom/integrations/backups/opencode/\(backup.lastPathComponent)",
            "  Use it:  in OpenCode, /models → Darkbloom. Your default model is unchanged.",
            "  Undo:    cp \(ToolIntegration.shellQuoted(backup.path)) \(ToolIntegration.shellQuoted(sandbox.openCodeFile.path))",
        ])

        let printed = sandbox.said.joined(separator: "\n")
        #expect(!printed.contains(sandbox.token))
        for file in sandbox.filesOtherThanTheKey() {
            #expect(!F.utf8(try Data(contentsOf: file)).contains(sandbox.token), "\(file.path) holds the key")
        }
    }

    @Test("a re-run without the catalog keeps the names, image support and limits it gave: nothing changes")
    func rerunWithoutTheCatalogKeepsItsDetails() async throws {
        let sandbox = try StepSandbox()
        #expect(await sandbox.step([.opencode, .hermes], catalog: StepSandbox.catalog)
            .run(endpoint: sandbox.endpoint, requests: "this Mac only"))
        let openCode = try Data(contentsOf: sandbox.openCodeFile)
        let hermes = try Data(contentsOf: sandbox.hermesFile)
        #expect(F.utf8(openCode).contains("\"name\": \"Qwen 3.8 27B (this Mac)\""))
        #expect(F.utf8(openCode).contains("\"limit\": { \"context\": 131072, \"output\": 8192 }"))
        #expect(F.utf8(hermes).contains("supports_vision: true"))

        // Offline, and against a catalog that doesn't list the models (another coordinator's): no write, no backup.
        let elsewhere = CatalogSnapshot(models: [], aliases: [])
        for catalog in [nil, elsewhere] {
            sandbox.said = []
            #expect(await sandbox.step([.opencode, .hermes], catalog: catalog)
                .run(endpoint: sandbox.endpoint, requests: "this Mac only"))
            let unreachable = "  Darkbloom's catalog wasn't reachable, so the models' names and image support stay as "
                + "they were."
            #expect(Array(sandbox.said.dropLast()) == [
                "✓ OpenCode already lists Darkbloom's 2 models (nothing changed).",
                "✓ Hermes already uses Darkbloom's current models (nothing changed).",
            ] + (catalog == nil ? [unreachable] : []) + ["  Requests: this Mac only"])
            #expect(try Data(contentsOf: sandbox.openCodeFile) == openCode)
            #expect(try Data(contentsOf: sandbox.hermesFile) == hermes)
        }
        #expect(sandbox.directory.allFiles().filter { $0.path.contains("/integrations/backups/") }.isEmpty)

        // Offline with a new model: the new one is set up with what is known, the others keep theirs, and one line
        // says to run the start again online.
        sandbox.said = []
        let more = StepSandbox.listed + [EndpointModel(id: "new-model", ownedBy: "this-mac", contextLength: 65_536)]
        #expect(await sandbox.step([.opencode, .hermes], listed: more)
            .run(endpoint: sandbox.endpoint, requests: "this Mac only"))
        #expect(sandbox.said.contains("  Darkbloom's catalog wasn't reachable: run `darkbloom --opencode --hermes` "
            + "again online for the models' names and image support."))
        let rewritten = F.utf8(try Data(contentsOf: sandbox.openCodeFile))
        #expect(rewritten.contains("\"name\": \"Qwen 3.8 27B (this Mac)\"")
            && rewritten.contains("\"name\": \"Gemma 4 26B (this Mac)\"")
            && rewritten.contains("\"name\": \"new-model (this Mac)\""))
        #expect(F.utf8(try Data(contentsOf: sandbox.hermesFile)).contains("supports_vision: true"))
    }

    @Test("a tool that isn't installed, an unreadable model list or Hermes' 64K floor: ✗, and Darkbloom keeps serving")
    func failuresSayWhyAndWriteNothing() async throws {
        let missing = try StepSandbox()
        #expect(await !missing.step([.opencode, .hermes], installed: [.opencode])
            .run(endpoint: missing.endpoint, requests: "this Mac only"))
        #expect(missing.said.first == "✗ Hermes isn't installed on this Mac. Install it, then run "
            + "`darkbloom --hermes` again.")
        #expect(missing.said.last == "Darkbloom keeps serving.")
        #expect(!FileManager.default.fileExists(atPath: missing.hermesFile.path))
        #expect(FileManager.default.fileExists(atPath: missing.openCodeFile.path))

        let unreadable = try StepSandbox()
        #expect(await !unreadable.step([.opencode], listed: nil).run(endpoint: unreadable.endpoint, requests: "x"))
        #expect(unreadable.said == [
            "✗ Couldn't read the models of this Mac's local API (HTTP 503), so OpenCode wasn't set up.",
            "Darkbloom keeps serving.",
        ])
        #expect(unreadable.filesOtherThanTheKey().isEmpty)

        let small = try StepSandbox()
        #expect(await !small.step([.opencode, .hermes], listed: [StepSandbox.listed[1]])
            .run(endpoint: small.endpoint, requests: "this Mac only"))
        #expect(small.said.contains("✗ Hermes needs a model with at least 64K context. Darkbloom's models here offer "
            + "at most 32K now; OpenCode can use them."))
        #expect(small.said.first == "✓ OpenCode can use Darkbloom: 1 model.")
        #expect(!FileManager.default.fileExists(atPath: small.hermesFile.path))

        let old = try StepSandbox()
        let step = ToolIntegrationStep(
            tools: [.opencode], environment: ToolIntegrationEnvironment(home: old.home, variables: [:]),
            provider: F.provider, findTool: { _ in .tooOld(version: "1.9.4") },
            fetchModels: { _ in StepSandbox.listed }, fetchCatalog: { nil }, say: { old.said.append($0) })
        #expect(await !step.run(endpoint: old.endpoint, requests: "this Mac only"))
        #expect(old.said == ["✗ OpenCode 1 is installed; Darkbloom sets up OpenCode 2. Run `opencode upgrade`, then "
            + "`darkbloom --opencode` again.", "Darkbloom keeps serving."])
        #expect(old.filesOtherThanTheKey().isEmpty)
    }

    @Test("a Hermes older than v0.20.2 is set up with one warning line: it can't read the key yet")
    func oldHermesWarns() async throws {
        let old = try StepSandbox()
        #expect(await old.step([.hermes], hermesVersion: "Hermes Agent v0.19.4 (2026.7.30)")
            .run(endpoint: old.endpoint, requests: "this Mac only"))
        let warning = "  Warning: Hermes v0.19.4 is older than v0.20.2 and can't read Darkbloom's key (`key_cmd`), so "
            + "Darkbloom will refuse its requests; update it with `hermes update`."
        #expect(old.said.contains(warning))
        #expect(old.said.firstIndex(of: warning) == old.said.firstIndex { $0.hasPrefix("  Left out:") }.map { $0 + 1 })
        let current = try StepSandbox()
        _ = await current.step([.hermes], hermesVersion: "Hermes Agent v0.23.0+12 (2026.9.24)")
            .run(endpoint: current.endpoint, requests: "this Mac only")
        #expect(!current.said.contains { $0.hasPrefix("  Warning:") })
    }

    @Test("no line of the step names a speed")
    func noSpeedInTheStep() async throws {
        let sandbox = try StepSandbox()
        _ = await sandbox.step([.opencode, .hermes]).run(endpoint: sandbox.endpoint, requests: "this Mac only")
        let text = (sandbox.said + [ToolIntegrationStep.noLocalAPI([.opencode, .hermes]),
                                    ToolIntegrationStep.notUp([.hermes], seconds: 30),
                                    ToolIntegrationStep.noPairAPI([.opencode]),
                                    ToolIntegrationStep.keyless(port: 8123),
                                    ToolIntegrationStep.noKeyFile([.opencode, .hermes], port: 8123)])
            .joined(separator: "\n")
        #expect(text.contains("✓ OpenCode can use Darkbloom") && text.contains("Choose \"Both, me first\""),
                "the check covers the step's lines")
        #expect(!text.contains("tok/s") && !text.lowercased().contains("tokens per second"))
        #expect(text.range(of: #"[0-9][0-9.,]*\s*[A-Za-z]*/s\b"#, options: .regularExpression) == nil)
    }
}
