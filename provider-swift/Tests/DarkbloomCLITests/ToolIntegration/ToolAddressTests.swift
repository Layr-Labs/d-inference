import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// A temp home with this Mac's key file and the pair's, where the tools are set up as `darkbloom --opencode --hermes`
/// sets them up. No tool runs, no port is bound, and no real home, OpenCode or Hermes config is read.
private final class AddressSandbox: @unchecked Sendable {
    let directory: TemporaryDirectory
    let home: URL
    let keyFile: URL
    let pairKeyFile: URL
    var said: [String] = []

    init() throws {
        directory = try TemporaryDirectory("tools-address")
        home = directory.file("home")
        keyFile = try directory.write(F.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
        pairKeyFile = try directory.write(F.freshToken(), to: "home/.darkbloom/cluster_local_token", mode: 0o600)
    }

    var environment: ToolIntegrationEnvironment { ToolIntegrationEnvironment(home: home, variables: [:]) }
    var openCodeFile: URL { home.appendingPathComponent(".config/opencode/opencode.jsonc") }
    var hermesFile: URL { home.appendingPathComponent(".hermes/config.yaml") }

    /// Sets `tools` up for the local API on `port` with the key in `keyFile` (this Mac's by default).
    func setUp(_ tools: [IntegrationTool], port: UInt16, keyFile: URL? = nil) async {
        let step = ToolIntegrationStep(
            tools: tools, environment: environment, provider: F.provider,
            findTool: { .installed(URL(fileURLWithPath: "/fake/\($0.rawValue)")) },
            fetchModels: { _ in [EndpointModel(id: "qwen3.8-27b", ownedBy: "this-mac", contextLength: 262_144)] },
            fetchCatalog: { nil }, say: { _ in })
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:\(port)/v1", keyFile: keyFile ?? self.keyFile)
        #expect(await step.run(endpoint: endpoint, requests: "this Mac only"))
    }

    /// A start serving `mode` on `port`, at `bind`.
    func serving(mode: LocalSettings.Mode = .both, port: UInt16, bind: String = "127.0.0.1",
                 noAuth: Bool = false) -> StartServing {
        StartServing(mode: mode, source: .saved, meFirst: mode == .both, meFirstIdleMinutes: 2, route: nil,
                     accountKeySaved: false, port: port, bind: bind, noAuth: noAuth)
    }

    /// What a start with `arguments` says after serving `mode` on `port`, on a Mac whose Bonjour name is
    /// `localHostName`.
    func notice(_ arguments: [String] = [], mode: LocalSettings.Mode = .both, port: UInt16, bind: String = "127.0.0.1",
                noAuth: Bool = false, localHostName: String? = "tester-mac") throws -> [String] {
        said = []
        try Start.parse(arguments).noteToolsPointingElsewhere(
            serving(mode: mode, port: port, bind: bind, noAuth: noAuth), environment: environment, provider: F.provider,
            keyFile: keyFile, localHostName: { localHostName }, say: { self.said.append($0) })
        return said
    }

    /// Points OpenCode's Darkbloom block at `url`, with this Mac's key file.
    func pointOpenCode(at url: String) throws {
        let settings = #"{ "baseURL": "\#(url)", "apiKey": "{file:~/.darkbloom/local_token}" }"#
        try directory.write(#"{ "providers": { "darkbloom": { "settings": \#(settings) } } }"#,
                            to: "home/.config/opencode/opencode.jsonc")
    }

    /// The tools' configs, byte for byte, and every backup.
    func snapshot() throws -> [Data?] {
        [try? Data(contentsOf: openCodeFile), try? Data(contentsOf: hermesFile)]
            + directory.allFiles().filter { $0.path.contains("/integrations/backups/") }.map { try? Data(contentsOf: $0) }
    }
}

@Suite("Start: the tools follow this Mac's local API", .serialized, .timeLimit(.minutes(1)))
struct ToolAddressTests {
    @Test("a later start on another port says so in one line, names the command, and changes no file")
    func aChangedPortIsSaidInOneLine() async throws {
        let sandbox = try AddressSandbox()
        await sandbox.setUp([.opencode, .hermes], port: 8123)
        let before = try sandbox.snapshot()
        #expect(try sandbox.notice(port: 8123).isEmpty, "the tools point at this Mac's local API")
        #expect(try sandbox.notice(port: 8124) == ["", "OpenCode and Hermes point at http://127.0.0.1:8123/v1, not "
            + "this Mac's local API (http://127.0.0.1:8124/v1): `darkbloom --opencode --hermes` points them there."])
        #expect(try sandbox.notice(mode: .local, port: 8124).count == 2, "Only me too")
        #expect(try sandbox.snapshot() == before, "a plain start never writes a tool's config")
    }

    @Test("only the tools set up for Darkbloom are named")
    func onlyToolsSetUpAreNamed() async throws {
        let sandbox = try AddressSandbox()
        #expect(try sandbox.notice(port: 8124).isEmpty, "no tool set up")
        await sandbox.setUp([.opencode], port: 8123)
        #expect(try sandbox.notice(port: 8124).last == "OpenCode points at http://127.0.0.1:8123/v1, not this Mac's "
            + "local API (http://127.0.0.1:8124/v1): `darkbloom --opencode` points it there.")
    }

    @Test("a tool reading another key file is named; the same key in another file is fine")
    func anotherKeyFileIsNamed() async throws {
        let sandbox = try AddressSandbox()
        await sandbox.setUp([.opencode, .hermes], port: 8123, keyFile: sandbox.pairKeyFile)
        #expect(try sandbox.notice(port: 8123).last == "OpenCode and Hermes read the key in "
            + "~/.darkbloom/cluster_local_token, not the one this Mac's local API takes (~/.darkbloom/local_token): "
            + "`darkbloom --opencode --hermes` points them there.")
        // Without a key (--no-auth) any file does.
        #expect(try sandbox.notice(port: 8123, noAuth: true).isEmpty)
        try Data(contentsOf: sandbox.keyFile).write(to: sandbox.pairKeyFile)
        #expect(try sandbox.notice(port: 8123).isEmpty, "the file holds this Mac's key")
    }

    @Test("tools that miss it in different ways get one line for both")
    func differentMissesGetOneLine() async throws {
        let sandbox = try AddressSandbox()
        await sandbox.setUp([.opencode], port: 8124)
        await sandbox.setUp([.hermes], port: 8123)
        #expect(try sandbox.notice(port: 8123).last == "OpenCode points at http://127.0.0.1:8124/v1, not this Mac's "
            + "local API (http://127.0.0.1:8123/v1): `darkbloom --opencode` points it there.")
        await sandbox.setUp([.hermes], port: 8123, keyFile: sandbox.pairKeyFile)
        #expect(try sandbox.notice(port: 8123).last == "OpenCode and Hermes don't point at this Mac's local API "
            + "(http://127.0.0.1:8123/v1): `darkbloom --opencode --hermes` points them there.")
    }

    @Test("a base URL with a slash at its end is the same address")
    func aTrailingSlashIsTheSameAddress() throws {
        let sandbox = try AddressSandbox()
        let settings = #"{ "baseURL": "http://127.0.0.1:8123/v1/", "apiKey": "{file:~/.darkbloom/local_token}" }"#
        try sandbox.directory.write(#"{ "providers": { "darkbloom": { "settings": \#(settings) } } }"#,
                                    to: "home/.config/opencode/opencode.jsonc")
        try sandbox.directory.write("providers:\n  darkbloom:\n    api: \"http://127.0.0.1:8123/v1/\"\n"
            + "    key_cmd: \"/bin/cat \(sandbox.keyFile.path)\"\n", to: "home/.hermes/config.yaml")
        #expect(try sandbox.notice(port: 8123).isEmpty)
        #expect(try sandbox.notice(port: 8124).last?.hasPrefix("OpenCode and Hermes point at "
            + "http://127.0.0.1:8123/v1/, not this Mac's local API") == true, "another port still is another address")
    }

    @Test("localhost, 127.0.0.1 and ::1 are this Mac, in any case; so is its .local name for an API on every address")
    func thisMacsNamesAreThisMac() throws {
        let sandbox = try AddressSandbox()
        for url in ["http://localhost:8123/v1", "http://[::1]:8123/v1", "HTTP://LocalHost:8123/v1/",
                    "http://127.0.0.1:8123/v1"] {
            try sandbox.pointOpenCode(at: url)
            #expect(try sandbox.notice(port: 8123).isEmpty, "\(url)")
            #expect(try sandbox.notice(port: 8124).last == "OpenCode points at \(url), not this Mac's local API "
                + "(http://127.0.0.1:8124/v1): `darkbloom --opencode` points it there.", "another port: \(url)")
        }
        // This Mac's Bonjour name, which `darkbloom local` prints for an API on every address.
        try sandbox.pointOpenCode(at: "http://Tester-Mac.local:8123/v1")
        #expect(try sandbox.notice(port: 8123, bind: "0.0.0.0").isEmpty)
        #expect(try sandbox.notice(port: 8123, bind: "127.0.0.1").count == 2, "an API on loopback alone isn't there")
        #expect(try sandbox.notice(port: 8123, bind: "0.0.0.0", localHostName: "other-mac").count == 2, "another Mac")
        #expect(try sandbox.notice(port: 8123, bind: "0.0.0.0", localHostName: nil).count == 2, "no name to know")
        // Another path, scheme or port is another address; the scheme's own port is its port.
        for url in ["http://localhost:8123/v2", "https://localhost:8123/v1", "http://localhost/v1"] {
            try sandbox.pointOpenCode(at: url)
            #expect(try sandbox.notice(port: 8123).count == 2, "\(url)")
        }
        #expect(ToolAddress.sameAddress("http://localhost/v1", "http://127.0.0.1:80/v1"))
        #expect(!ToolAddress.sameAddress("http://192.168.1.5:8123/v1", "http://127.0.0.1:8123/v1"))
    }

    @Test("a plain start says it beside its background provider and its Only me server; a service's child never does")
    func theStartsHooksSayIt() async throws {
        let sandbox = try AddressSandbox()
        await sandbox.setUp([.opencode], port: 8123)
        let serving = sandbox.serving(port: 8124)
        let line = ["", "OpenCode points at http://127.0.0.1:8123/v1, not this Mac's local API (http://127.0.0.1:8124/v1): "
            + "`darkbloom --opencode` points it there."]
        func note(_ start: Start) -> (StartServing) -> Void {
            { start.noteToolsPointingElsewhere($0, environment: sandbox.environment, provider: F.provider,
                                               keyFile: sandbox.keyFile, localHostName: { nil },
                                               say: { sandbox.said.append($0) }) }
        }
        let coordinator = "wss://coordinator.invalid/ws/provider"
        // Beside the background provider: the line, and no wait for an API it has no tool to set up for.
        sandbox.said = []
        let start = try Start.parse([])
        try await start.setUpToolsBesideDaemon(serving: serving, coordinatorURL: coordinator, waitForAPI: { _, _ in
            Issue.record("a start without a tool flag waits for no API")
            return .notUp
        }, noteTools: note(start))
        #expect(sandbox.said == line)
        // Beside the Only me server: the line in a terminal; none in a service's child, whose lines go to a log.
        let info = LocalEndpoint.Info(host: "127.0.0.1", port: 8124, apiKey: "dk-local-fixture", version: "test", pid: 1,
                                      updatedAt: "")
        for (arguments, expected) in [([String](), line), (["--foreground"], [])] {
            sandbox.said = []
            let start = try Start.parse(arguments)
            start.setUpToolsBesideLocalServer(info, serving: serving, coordinatorURL: coordinator, noteTools: note(start))
            #expect(sandbox.said == expected, "\(arguments)")
        }
    }

    @Test("no line with a tool flag (the start points the tools there itself) or without a local API")
    func noLineWhenTheStartSetsToolsUpOrServesNoAPI() async throws {
        let sandbox = try AddressSandbox()
        await sandbox.setUp([.opencode, .hermes], port: 8123)
        #expect(try sandbox.notice(["--opencode"], port: 8124).isEmpty)
        #expect(try sandbox.notice(mode: .network, port: 8124).isEmpty)
    }

    @Test("the tools' files are read back as Darkbloom writes them, a key file under ~ or with quotes in its path")
    func pointersReadBack() throws {
        for keyFile in ["/Users/tester/.darkbloom/local_token", "/Users/o'neil/My Keys/local_token"] {
            let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8001/v1",
                                               keyFile: URL(fileURLWithPath: keyFile))
            let openCode = try #require(F.newText(OpenCodeConfigPlan.plan(
                existing: nil, fileName: "opencode.jsonc", endpoint: endpoint, models: [F.qwen], provider: F.provider,
                home: F.home)))
            let hermes = try #require(F.newText(HermesConfigPlan.plan(
                existing: nil, endpoint: endpoint, models: [F.qwen], provider: F.provider)))
            for pointer in [OpenCodeConfigPlan.pointer(in: Data(openCode.utf8), provider: F.provider, home: F.home),
                            HermesConfigPlan.pointer(in: Data(hermes.utf8), provider: F.provider)] {
                #expect(pointer?.baseURL == "http://127.0.0.1:8001/v1" && pointer?.keyFile?.path == keyFile,
                        "\(String(describing: pointer))")
            }
        }
        // A key the owner gives some other way, and a file without Darkbloom's block.
        let envKey = #"{ "providers": { "darkbloom": { "settings": { "apiKey": "{env:KEY}" } } } }"#
        #expect(OpenCodeConfigPlan.pointer(in: Data(envKey.utf8), provider: F.provider, home: F.home)
            == ToolPointer(baseURL: nil, keyFile: nil))
        #expect(OpenCodeConfigPlan.pointer(in: Data(#"{ "providers": {} }"#.utf8), provider: F.provider,
                                           home: F.home) == nil)
        #expect(HermesConfigPlan.pointer(in: Data("providers:\n  other:\n    api: x\n".utf8), provider: F.provider)
            == nil)
    }

    @Test("a key command or file reference Darkbloom doesn't write names no key file")
    func otherKeyFormsNameNoFile() {
        let api = "http://127.0.0.1:8001/v1"
        for command in ["pass show darkbloom", "/bin/cat .darkbloom/local_token", "/bin/cat '/Users/tester/unclosed"] {
            let text = "providers:\n  darkbloom:\n    api: \"\(api)\"\n    key_cmd: \"\(command)\"\n"
            #expect(HermesConfigPlan.pointer(in: Data(text.utf8), provider: F.provider)
                == ToolPointer(baseURL: api, keyFile: nil), "\(command)")
        }
        for reference in ["{file:.darkbloom/local_token}", "dk-local-written-in-the-file"] {
            let settings = #"{ "baseURL": "\#(api)", "apiKey": "\#(reference)" }"#
            let text = #"{ "providers": { "darkbloom": { "settings": \#(settings) } } }"#
            #expect(OpenCodeConfigPlan.pointer(in: Data(text.utf8), provider: F.provider, home: F.home)
                == ToolPointer(baseURL: api, keyFile: nil), "\(reference)")
        }
    }
}
