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

    /// What a start with `arguments` says after serving `mode` on `port`.
    func notice(_ arguments: [String] = [], mode: LocalSettings.Mode = .both, port: UInt16,
                noAuth: Bool = false) throws -> [String] {
        said = []
        let serving = StartServing(mode: mode, source: .saved, meFirst: mode == .both, meFirstIdleMinutes: 2,
                                   route: nil, accountKeySaved: false, port: port, bind: "127.0.0.1", noAuth: noAuth)
        try Start.parse(arguments).noteToolsPointingElsewhere(serving, environment: environment, provider: F.provider,
                                                              keyFile: keyFile, say: { self.said.append($0) })
        return said
    }

    /// The tools' configs, byte for byte, and every backup.
    func snapshot() throws -> [Data?] {
        [try? Data(contentsOf: openCodeFile), try? Data(contentsOf: hermesFile)]
            + directory.allFiles().filter { $0.path.contains("/integrations/backups/") }.map { try? Data(contentsOf: $0) }
    }
}

@Suite("Start: the tools follow this Mac's local API", .serialized)
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
}
