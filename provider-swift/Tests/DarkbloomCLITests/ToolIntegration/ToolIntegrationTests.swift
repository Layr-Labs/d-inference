import Foundation
import ProviderCore
import Testing

@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// A temp home with a Darkbloom key file in it, and nothing else.
private struct Sandbox {
    let directory: TemporaryDirectory
    let token = F.freshToken()
    let home: URL
    let keyFile: URL

    init() throws {
        directory = try TemporaryDirectory("tool-integration-home")
        home = directory.file("home")
        keyFile = try directory.write(token, to: "home/.darkbloom/local_token", mode: 0o600)
    }

    var endpoint: IntegrationEndpoint { IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile) }

    func environment(_ variables: [String: String] = [:]) -> ToolIntegrationEnvironment {
        ToolIntegrationEnvironment(home: home, variables: variables)
    }

    /// Every file under the sandbox other than the key file itself.
    func filesOtherThanTheKey() -> [URL] {
        directory.allFiles().filter { $0.resolvingSymlinksInPath().path != keyFile.resolvingSymlinksInPath().path }
    }
}

private func configFile(of outcome: ToolConfigWriter.Outcome) -> URL {
    switch outcome {
    case .unchanged(let file, _), .planned(let file, _, _), .written(let file, _, _, _), .refused(let file, _): file
    }
}

@Suite("Tool integration")
struct ToolIntegrationTests {
    @Test("both tools are set up in their own files, again with no change, and no file holds the key")
    func configuresBothToolsWithoutTheKey() throws {
        let sandbox = try Sandbox()
        let environment = sandbox.environment()
        var outcomes: [ToolConfigWriter.Outcome] = []
        for tool in IntegrationTool.allCases {
            outcomes.append(try ToolIntegration.configure(tool, endpoint: sandbox.endpoint, models: F.models,
                                                          provider: F.provider, environment: environment))
        }
        #expect(configFile(of: outcomes[0]).path == sandbox.home.path + "/.config/opencode/opencode.jsonc")
        #expect(configFile(of: outcomes[1]).path == sandbox.home.path + "/.hermes/config.yaml")
        for outcome in outcomes {
            guard case .written(_, nil, let undo, _) = outcome else {
                Issue.record("expected a new file, got \(outcome)")
                continue
            }
            #expect(undo.hasPrefix("rm '"))
        }
        // A new Hermes config starts owner-only: it can come to hold other providers' keys. OpenCode's holds none.
        #expect(posixMode(configFile(of: outcomes[0])) == 0o644)
        #expect(posixMode(configFile(of: outcomes[1])) == 0o600)
        let opencode = try String(contentsOf: configFile(of: outcomes[0]), encoding: .utf8)
        #expect(opencode.contains("\"apiKey\": \"{file:~/.darkbloom/local_token}\""))
        #expect(opencode.contains("\"maxTokensField\": \"max_tokens\""))
        let hermes = try String(contentsOf: configFile(of: outcomes[1]), encoding: .utf8)
        #expect(hermes.contains("key_cmd: \"/bin/cat \(sandbox.keyFile.path)\""))
        #expect(hermes.contains("max_tokens: 24576"))

        // The same run again writes nothing and makes no backup.
        for tool in IntegrationTool.allCases {
            let again = try ToolIntegration.configure(tool, endpoint: sandbox.endpoint, models: F.models,
                                                      provider: F.provider, environment: environment)
            guard case .unchanged = again else {
                Issue.record("expected no change for \(tool), got \(again)")
                continue
            }
        }
        #expect(!FileManager.default.fileExists(atPath: environment.stateDirectory.appendingPathComponent("backups").path))

        // A changed model list is written with a backup in Darkbloom's own folder.
        let changed = try ToolIntegration.configure(.hermes, endpoint: sandbox.endpoint, models: [F.qwen],
                                                    provider: F.provider, environment: environment)
        guard case .written(_, let backup?, let undo, let summary) = changed else {
            Issue.record("expected a backed-up change, got \(changed)")
            return
        }
        #expect(backup.path.hasPrefix(environment.stateDirectory.path + "/backups/hermes/config.yaml."))
        #expect(undo == "cp '\(backup.path)' '\(configFile(of: changed).path)'")
        #expect(summary.models == ["qwen3.8-27b"])

        // Both configs, the one backup and Darkbloom's lock.
        let files = sandbox.filesOtherThanTheKey()
        #expect(files.count == 4)
        for written in files {
            #expect(!ToolIntegrationFixtures.utf8(try Data(contentsOf: written)).contains(sandbox.token),
                    "\(written.path) holds the key")
        }
        for outcome in outcomes + [changed] {
            #expect(!String(describing: outcome).contains(sandbox.token))
        }
    }

    /// OpenCode loads both global files, `.jsonc` last. With the owner's default in `opencode.json` and none in
    /// `opencode.jsonc`, a `model` added to `.jsonc` would override the owner's. (The independent review's test.)
    @Test("the owner's default model in opencode.json is kept when Darkbloom edits opencode.jsonc")
    func defaultModelInTheSiblingFile() throws {
        let directory = try TemporaryDirectory("review-both-files")
        let home = directory.file("home")
        let keyFile = try directory.write(F.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
        try directory.write("{\n  \"model\": \"omlx/Qwen3.6-35B-A3B-4bit\"\n}\n", to: "home/.config/opencode/opencode.json")
        try directory.write("{\n  \"theme\": \"dark\"\n}\n", to: "home/.config/opencode/opencode.jsonc")
        let outcome = try ToolIntegration.configure(
            .opencode, endpoint: IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile),
            models: F.models, provider: F.provider, environment: ToolIntegrationEnvironment(home: home, variables: [:]))
        guard case .written(let file, _, _, let summary) = outcome else {
            Issue.record("expected a written outcome, got \(outcome)")
            return
        }
        #expect(file.lastPathComponent == "opencode.jsonc")
        #expect(summary.defaultModel == nil)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("\"model\""))
    }

    @Test("XDG_CONFIG_HOME and HERMES_HOME move the files; a dry run writes nothing")
    func environmentAndDryRun() throws {
        let sandbox = try Sandbox()
        let xdg = sandbox.directory.file("xdg")
        let hermesHome = sandbox.directory.file("hermes-profile")
        let environment = sandbox.environment(["XDG_CONFIG_HOME": xdg.path, "HERMES_HOME": hermesHome.path])
        let opencode = try ToolIntegration.configure(.opencode, endpoint: sandbox.endpoint, models: F.models,
                                                     provider: F.provider, environment: environment, dryRun: true)
        guard case .planned(let file, let contents, _) = opencode else {
            Issue.record("expected a planned outcome, got \(opencode)")
            return
        }
        #expect(file.path == xdg.path + "/opencode/opencode.jsonc")
        #expect(F.utf8(contents).contains("\"darkbloom\": {"))
        #expect(sandbox.filesOtherThanTheKey().isEmpty)

        let hermes = try ToolIntegration.configure(.hermes, endpoint: sandbox.endpoint, models: F.models,
                                                   provider: F.provider, environment: environment)
        #expect(ToolIntegration.displayPath(configFile(of: hermes), home: sandbox.home) == hermesHome.path + "/config.yaml")
    }

    @Test("Hermes refuses before anything is written when no model has 64K context")
    func hermesFloorWritesNothing() throws {
        let sandbox = try Sandbox()
        let outcome = try ToolIntegration.configure(.hermes, endpoint: sandbox.endpoint, models: [F.gemma],
                                                    provider: F.provider, environment: sandbox.environment())
        guard case .refused(_, let refusal) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(refusal.kind == .models)
        #expect(sandbox.filesOtherThanTheKey().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".hermes").path))
    }

    @Test("paths print under ~ inside the home and absolute outside it; undo paths are quoted for the shell")
    func displayAndQuoting() {
        let home = URL(fileURLWithPath: "/Users/tester")
        #expect(ToolIntegration.displayPath(URL(fileURLWithPath: "/Users/tester/.hermes/config.yaml"), home: home)
            == "~/.hermes/config.yaml")
        #expect(ToolIntegration.displayPath(URL(fileURLWithPath: "/Users/testerx/a"), home: home) == "/Users/testerx/a")
        #expect(ToolIntegration.shellQuoted("/a b/it's") == "'/a b/it'\\''s'")
        #expect(ToolIntegration.shellQuoted("/a/b", onlyIfNeeded: true) == "/a/b")
        #expect(ToolIntegration.shellQuoted("/a b", onlyIfNeeded: true) == "'/a b'")
    }

    @Test("the provider is the build's own: its CLI name and display name")
    func providerIdentity() {
        #expect(IntegrationProvider.current == IntegrationProvider(
            id: BuildEnvironment.current.cliName, name: BuildEnvironment.current.appDisplayName))
    }

    // The live endpoint reads the discovery folder through the process-wide DARKBLOOM_LOCAL_DIR, so it runs in a
    // child process that alone points it at a temp folder.
    @Test("the live endpoint is local.json's address and port, with the key file that holds its key")
    func liveEndpoint() async {
        await #expect(processExitsWith: .success) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tool-integration-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1)
            func publish(port: UInt16, key: String, pid: Int32 = getpid()) throws {
                try LocalEndpoint.writeInfo(LocalEndpoint.Info(
                    host: "0.0.0.0", port: port, apiKey: key, version: "9.9.9", pid: pid, updatedAt: "t"))
            }
            var checks: [Bool] = []
            checks.append(IntegrationEndpoint.live() == nil)

            let own = try LocalEndpoint.loadOrCreateToken()
            try publish(port: 8123, key: own)
            checks.append(IntegrationEndpoint.live()?.baseURL == "http://127.0.0.1:8123/v1")
            checks.append(IntegrationEndpoint.live()?.keyFile.path == directory.appendingPathComponent("local_token").path)

            let pair = try LocalEndpoint.loadOrCreateClusterToken()
            try publish(port: 8002, key: pair)
            checks.append(IntegrationEndpoint.live()?.baseURL == "http://127.0.0.1:8002/v1")
            checks.append(IntegrationEndpoint.live()?.keyFile.path
                == directory.appendingPathComponent("cluster_local_token").path)

            try publish(port: 8123, key: "")
            checks.append(IntegrationEndpoint.live() == nil)
            try publish(port: 8123, key: own, pid: 0)
            checks.append(IntegrationEndpoint.live() == nil)
            try? FileManager.default.removeItem(at: directory)
            exit(checks.allSatisfy { $0 } ? 0 : 1)
        }
    }
}
