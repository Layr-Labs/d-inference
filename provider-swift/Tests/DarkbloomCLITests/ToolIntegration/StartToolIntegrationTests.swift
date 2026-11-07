import ArgumentParser
import Foundation
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
              listed: [EndpointModel]? = StepSandbox.listed, hermesVersion: String? = nil) -> ToolIntegrationStep {
        ToolIntegrationStep(
            tools: tools, environment: ToolIntegrationEnvironment(home: home, variables: [:]), provider: F.provider,
            findTool: { installed.contains($0) ? .installed(URL(fileURLWithPath: "/fake/\($0.rawValue)")) : .missing },
            fetchModels: { _ in
                guard let listed else { throw IntegrationModelsError.http(status: 503) }
                return listed
            },
            fetchCatalog: { nil },
            say: { self.said.append($0) },
            versionOutput: { tool, _ in tool == .hermes ? hermesVersion : nil })
    }

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
    ]

    @Test("they are refused with --network, --no-auth, a cluster member and the --foreground service",
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
            + "use. Choose \"Both, me first\" (`darkbloom start --me-first --opencode --hermes`) or \"Only me\" "
            + "(`darkbloom start --local --opencode --hermes`). Nothing was started or saved."
        for (terminal, answers) in [(false, [String]()), (true, ["2"])] {
            var remaining = answers
            let start = try Start.parse(["--opencode", "--hermes", "--config", config.path])
            do {
                _ = try start.resolveServing(environment: ServingEnvironment(
                    terminal: terminal, readInput: { remaining.isEmpty ? nil : remaining.removeFirst() },
                    emit: { _ in }, accountKeySaved: { false }, ownLivePort: { nil }, isFree: { _ in true }))
                Issue.record("no local API must refuse the tools")
            } catch let error as ValidationError {
                #expect(error.message == refusal)
            }
        }
        #expect(try Data(contentsOf: config) == before)
        #expect(ToolIntegrationStep.noLocalAPI([.opencode]).hasSuffix("(`darkbloom start --local --opencode`)."))
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
        #expect(found == IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile))
        let none = await Start.waitForLocalAPI(port: 8123, seconds: 0, live: { nil }, keyFile: { _ in keyFile },
                                               pause: {})
        #expect(none == nil)
        #expect(ToolIntegrationStep.notUp([.opencode], seconds: 30) == "✗ This Mac's local API didn't answer within 30 "
            + "seconds, so OpenCode wasn't set up. Run `darkbloom start --opencode` again once `darkbloom local` shows it.")
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
            "  (Model details unavailable offline; run this again online to refresh them.)",
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

    @Test("a tool that isn't installed, an unreadable model list or Hermes' 64K floor: ✗, and Darkbloom keeps serving")
    func failuresSayWhyAndWriteNothing() async throws {
        let missing = try StepSandbox()
        #expect(await !missing.step([.opencode, .hermes], installed: [.opencode])
            .run(endpoint: missing.endpoint, requests: "this Mac only"))
        #expect(missing.said.first == "✗ Hermes isn't installed on this Mac. Install it, then run "
            + "`darkbloom start --hermes` again.")
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
            + "`darkbloom start --opencode` again.", "Darkbloom keeps serving."])
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
                                    ToolIntegrationStep.noPairAPI([.opencode])]).joined(separator: "\n")
        #expect(text.contains("✓ OpenCode can use Darkbloom") && text.contains("Choose \"Both, me first\""),
                "the check covers the step's lines")
        #expect(!text.contains("tok/s") && !text.lowercased().contains("tokens per second"))
        #expect(text.range(of: #"[0-9][0-9.,]*\s*[A-Za-z]*/s\b"#, options: .regularExpression) == nil)
    }
}
