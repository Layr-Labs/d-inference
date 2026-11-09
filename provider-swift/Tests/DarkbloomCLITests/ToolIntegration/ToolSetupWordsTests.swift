import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// A temp home with Darkbloom's key file and the tools' configs as a user's Mac has them, and a recorder for what the
/// step says. No tool runs, no port is bound, and no real home, OpenCode or Hermes config is read.
private final class WordsSandbox: @unchecked Sendable {
    let directory: TemporaryDirectory
    let home: URL
    let keyFile: URL
    var said: [String] = []

    init() throws {
        directory = try TemporaryDirectory("tool-words")
        home = directory.file("home")
        keyFile = try directory.write(F.freshToken(), to: "home/.darkbloom/local_token", mode: 0o600)
    }

    /// A pair's API on every address, as journey 2a found it on the leading Mac.
    func endpoint(pair: Bool = false) -> IntegrationEndpoint {
        IntegrationEndpoint(baseURL: "http://127.0.0.1:8001/v1", keyFile: keyFile, servesThePair: pair)
    }

    var openCodeJSON: URL { home.appendingPathComponent(".config/opencode/opencode.json") }
    var openCodeJSONC: URL { home.appendingPathComponent(".config/opencode/opencode.jsonc") }
    var hermesFile: URL { home.appendingPathComponent(".hermes/config.yaml") }

    static let qwen = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    static let catalog = CatalogSnapshot(models: [
        CatalogModel(id: qwen, s3Name: qwen, displayName: "Qwen 3.8 27B", sizeGb: 1, maxContextLength: 262_144,
                     maxOutputLength: 65_536, capabilities: ["tools", "vision"]),
    ], aliases: [])

    /// The start's environment variables (`XDG_STATE_HOME`, `XDG_CONFIG_HOME`).
    var variables: [String: String] = [:]

    /// OpenCode's TUI's remembered `/models` picks, as OpenCode 2.2.6 writes them: `model.json` in its state folder.
    func remember(_ picks: [(provider: String, model: String)], in state: String = "home/.local/state") throws {
        let recent = picks.map { #"{ "providerID": "\#($0.provider)", "modelID": "\#($0.model)" }"# }
        try directory.write(#"{ "recent": [\#(recent.joined(separator: ", "))], "favorite": [], "variant": {} }"#,
                            to: "\(state)/opencode/model.json")
    }

    func step(_ tools: [IntegrationTool], catalog: CatalogSnapshot? = WordsSandbox.catalog) -> ToolIntegrationStep {
        ToolIntegrationStep(
            tools: tools, environment: ToolIntegrationEnvironment(home: home, variables: variables), provider: F.provider,
            findTool: { .installed(URL(fileURLWithPath: "/fake/\($0.rawValue)")) },
            fetchModels: { _ in [EndpointModel(id: Self.qwen, ownedBy: "this-mac", contextLength: 262_144)] },
            fetchCatalog: { catalog }, say: { [self] in said.append($0) })
    }

    /// What the step says for `tools`, from its first line to the undo (or `Left out:`), without the backup's name.
    func run(_ tools: [IntegrationTool], pair: Bool = false,
             catalog: CatalogSnapshot? = WordsSandbox.catalog) async -> [String] {
        said = []
        #expect(await step(tools, catalog: catalog).run(endpoint: endpoint(pair: pair), requests: "this Mac only"))
        return said.filter { !$0.hasPrefix("  Requests:") && !$0.hasPrefix("  Other tools:") }
            .map { $0.hasPrefix("  Backup:") ? "  Backup:  <backup>" : $0 }
            .map { $0.replacingOccurrences(of: #"Undo:    cp '[^']*' "#, with: "Undo:    cp <backup> ",
                                           options: .regularExpression) }
    }
}

/// His `opencode.json` in journey 2a: two providers of his own and no default model.
private let hisOpenCodeJSON = """
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "exo": { "npm": "@ai-sdk/openai-compatible", "options": { "baseURL": "http://127.0.0.1:52415/v1" } },
    "omlx": { "npm": "@ai-sdk/openai-compatible", "options": { "baseURL": "http://127.0.0.1:8000/v1" } }
  }
}

"""

/// His `~/.hermes/config.yaml` in journey 2a: the main model is another provider's.
private let hisHermes = """
model:
  default: gpt-6-astra
  provider: opencodex
  base_url: http://127.0.0.1:10100/v1
  api_mode: chat_completions
  api_key: ${OPENCODEX_HERMES_API_KEY}
toolsets:
  - hermes-cli

"""

@Suite("Start: --opencode and --hermes say what they did to your default, and where the models run", .serialized)
struct ToolSetupWordsTests {
    // MARK: - OpenCode's default (J2-g)

    @Test("no global file sets a default: Darkbloom's becomes it, said on its own line, with the undo")
    func noDefaultAnywhereSetsDarkbloomsAndSaysSo() async throws {
        let sandbox = try WordsSandbox()
        try sandbox.directory.write(hisOpenCodeJSON, to: "home/.config/opencode/opencode.json")
        try sandbox.directory.write("{\n  \"theme\": \"dark\"\n}\n", to: "home/.config/opencode/opencode.jsonc")
        let json = try Data(contentsOf: sandbox.openCodeJSON)
        #expect(await sandbox.run([.opencode]) == [
            "✓ OpenCode can use Darkbloom: 1 model.",
            "  Changed: ~/.config/opencode/opencode.jsonc (added the \"darkbloom\" provider and the default model; "
                + "nothing else changed)",
            "  Backup:  <backup>",
            "  New OpenCode sessions now use Darkbloom's Qwen 3.8 27B. To go back, remove \"model\" from "
                + "~/.config/opencode/opencode.jsonc or run the Undo below.",
            "  Undo:    cp <backup> \(ToolIntegration.shellQuoted(sandbox.openCodeJSONC.path))",
        ])
        #expect(F.utf8(try Data(contentsOf: sandbox.openCodeJSONC))
            .contains("\"model\": \"darkbloom/\(WordsSandbox.qwen)\""))
        #expect(try Data(contentsOf: sandbox.openCodeJSON) == json, "his opencode.json is never touched")

        // A new file says the same.
        let fresh = try WordsSandbox()
        let lines = await fresh.run([.opencode])
        #expect(lines.prefix(3) == [
            "✓ OpenCode can use Darkbloom: 1 model.",
            "  Changed: ~/.config/opencode/opencode.jsonc (a new file with the \"darkbloom\" provider and the default "
                + "model)",
            "  New OpenCode sessions now use Darkbloom's Qwen 3.8 27B. To go back, remove \"model\" from "
                + "~/.config/opencode/opencode.jsonc or run the Undo below.",
        ])
    }

    @Test("a model picked with /models, which OpenCode remembers, stays its default: no model is written")
    func aRememberedPickStays() async throws {
        let sandbox = try WordsSandbox()
        try sandbox.directory.write(hisOpenCodeJSON, to: "home/.config/opencode/opencode.json")
        try sandbox.remember([("omlx", "qwen3.6"), ("exo", "llama-3.3-70b")])
        #expect(await sandbox.run([.opencode]) == [
            "✓ OpenCode can use Darkbloom: 1 model.",
            "  Changed: ~/.config/opencode/opencode.json (added the \"darkbloom\" provider; nothing else changed)",
            "  Backup:  <backup>",
            "  Pick Darkbloom once with /models; OpenCode remembers it.",
            "  Undo:    cp <backup> \(ToolIntegration.shellQuoted(sandbox.openCodeJSON.path))",
        ])
        let written = F.utf8(try Data(contentsOf: sandbox.openCodeJSON))
        #expect(!written.contains("\"model\""), "\(written)")
        #expect(written.contains("\"omlx\": { \"npm\""), "his providers stay")
        // A run again changes nothing.
        #expect(await sandbox.run([.opencode]) == ["✓ OpenCode already lists Darkbloom's 1 model (nothing changed)."])

        // OpenCode's state folder under XDG_STATE_HOME, as it finds it; then ~/.local/state isn't read.
        let xdg = try WordsSandbox()
        xdg.variables = ["XDG_STATE_HOME": xdg.directory.file("state").path]
        try xdg.remember([("omlx", "qwen3.6")], in: "state")
        #expect(await xdg.run([.opencode]).contains("  Pick Darkbloom once with /models; OpenCode remembers it."))
        let elsewhere = try WordsSandbox()
        elsewhere.variables = ["XDG_STATE_HOME": elsewhere.directory.file("state").path]
        try elsewhere.remember([("omlx", "qwen3.6")])
        _ = await elsewhere.run([.opencode])
        #expect(F.utf8(try Data(contentsOf: elsewhere.openCodeJSONC)).contains("\"model\": \"darkbloom/"),
                "the pick is in another state folder than OpenCode's")

        // A config's default outranks a remembered pick in OpenCode, so it is the one named.
        let both = try WordsSandbox()
        try both.directory.write("{\n  \"model\": \"exo/llama-3.3-70b\"\n}\n", to: "home/.config/opencode/opencode.json")
        try both.remember([("omlx", "qwen3.6")])
        #expect(await both.run([.opencode]).contains("  Your default stays exo/llama-3.3-70b; pick Darkbloom with /models."))
    }

    @Test("no pick OpenCode would read (none, only favorites, malformed or unreadable): Darkbloom's becomes the default")
    func noRememberedPickSetsDarkbloomsDefault() async throws {
        let empty = #"{ "recent": [], "favorite": [{ "providerID": "omlx", "modelID": "qwen3.6" }], "variant": {} }"#
        let unnamed = #"{ "recent": [{ "providerID": "", "modelID": "qwen3.6" }, { "providerID": "omlx" }] }"#
        for text in [empty, unnamed, "{ \"recent\": ", "[]"] {
            let sandbox = try WordsSandbox()
            try sandbox.directory.write(text, to: "home/.local/state/opencode/model.json")
            #expect(await sandbox.run([.opencode]).contains(
                "  New OpenCode sessions now use Darkbloom's Qwen 3.8 27B. To go back, remove \"model\" from "
                    + "~/.config/opencode/opencode.jsonc or run the Undo below."), "\(text)")
        }
    }

    @Test("a default in any global file stays, named; none is written, in either file")
    func aDefaultElsewhereStays() async throws {
        let sandbox = try WordsSandbox()
        let mine = hisOpenCodeJSON.replacingOccurrences(of: "\"provider\": {",
                                                        with: "\"model\": \"exo/llama-3.3-70b\",\n  \"provider\": {")
        try sandbox.directory.write(mine, to: "home/.config/opencode/opencode.json")
        try sandbox.directory.write("{\n  \"theme\": \"dark\"\n}\n", to: "home/.config/opencode/opencode.jsonc")
        #expect(await sandbox.run([.opencode]) == [
            "✓ OpenCode can use Darkbloom: 1 model.",
            "  Changed: ~/.config/opencode/opencode.jsonc (added the \"darkbloom\" provider; nothing else changed)",
            "  Backup:  <backup>",
            "  Your default stays exo/llama-3.3-70b; pick Darkbloom with /models.",
            "  Undo:    cp <backup> \(ToolIntegration.shellQuoted(sandbox.openCodeJSONC.path))",
        ])
        #expect(!F.utf8(try Data(contentsOf: sandbox.openCodeJSONC)).contains("\"model\""))

        // The file Darkbloom edits sets it: it stays too.
        let own = try WordsSandbox()
        try own.directory.write("{\n  \"model\": \"omlx/qwen\"\n}\n", to: "home/.config/opencode/opencode.json")
        #expect(await own.run([.opencode]).contains("  Your default stays omlx/qwen; pick Darkbloom with /models."))
    }

    @Test("a default the global files set without a model's name stays, and the line says so without one")
    func aDefaultWithoutANameStays() async throws {
        for json in ["{ \"model\": \"\" }\n", "{ \"model\": null }\n", "{ \"model\": \n"] {
            let sandbox = try WordsSandbox()
            try sandbox.directory.write(json, to: "home/.config/opencode/opencode.json")
            try sandbox.directory.write("{\n  \"theme\": \"dark\"\n}\n", to: "home/.config/opencode/opencode.jsonc")
            #expect(await sandbox.run([.opencode]) == [
                "✓ OpenCode can use Darkbloom: 1 model.",
                "  Changed: ~/.config/opencode/opencode.jsonc (added the \"darkbloom\" provider; nothing else changed)",
                "  Backup:  <backup>",
                "  Your default model stays as your config sets it; pick Darkbloom with /models.",
                "  Undo:    cp <backup> \(ToolIntegration.shellQuoted(sandbox.openCodeJSONC.path))",
            ], "\(json)")
            #expect(!F.utf8(try Data(contentsOf: sandbox.openCodeJSONC)).contains("\"model\""), "\(json)")
        }
    }

    @Test("OpenCode 1's config.json is no global file of OpenCode 2's: a model there sets no default")
    func legacyConfigJSONSetsNoDefault() async throws {
        let sandbox = try WordsSandbox()
        try sandbox.directory.write("{ \"model\": \"anthropic/claude-sonnet-4\" }\n", to: "home/.config/opencode/config.json")
        #expect(await sandbox.run([.opencode]).contains(
            "  New OpenCode sessions now use Darkbloom's Qwen 3.8 27B. To go back, remove \"model\" from "
                + "~/.config/opencode/opencode.jsonc or run the Undo below."))
    }

    // MARK: - Hermes' main model

    @Test("Hermes: Darkbloom becomes the main model, and the line names the one before and how to switch back")
    func hermesNamesTheMainModelBefore() async throws {
        let sandbox = try WordsSandbox()
        try sandbox.directory.write(hisHermes, to: "home/.hermes/config.yaml")
        #expect(await sandbox.run([.hermes]) == [
            "✓ Hermes can use Darkbloom: 1 model.",
            "  Changed: ~/.hermes/config.yaml (added the \"darkbloom\" provider and made it the main model)",
            "  Backup:  <backup>",
            "  New Hermes chats now use Darkbloom's Qwen 3.8 27B (before: gpt-6-astra via opencodex). Switch back: "
                + "hermes model",
            "  Undo:    cp <backup> \(ToolIntegration.shellQuoted(sandbox.hermesFile.path))   ·   Chats already open "
                + "keep their model.",
        ])
        // No main model before: nothing to name.
        let fresh = try WordsSandbox()
        #expect(await fresh.run([.hermes]).contains(
            "  New Hermes chats now use Darkbloom's Qwen 3.8 27B. Switch back: hermes model"))
    }

    // MARK: - Where it serves (J2-e) and where the models run (J2-f)

    @Test("a running API is named by the address a tool uses, never its bind address")
    func alreadyServesNamesTheURL() {
        let everyAddress = LocalEndpoint.Info(host: "0.0.0.0", port: 8001, apiKey: "dk-local-fixture", version: "t",
                                              pid: 41, updatedAt: "")
        #expect(ToolIntegrationStep.alreadyServes(everyAddress, tools: [.opencode])
            == "Darkbloom already serves at http://127.0.0.1:8001/v1; setting up OpenCode for it.")
        let loopback = LocalEndpoint.Info(host: "127.0.0.1", port: 8002, apiKey: "k", version: "t", pid: 41,
                                          updatedAt: "")
        #expect(ToolIntegrationStep.alreadyServes(loopback, tools: [.opencode, .hermes])
            == "Darkbloom already serves at http://127.0.0.1:8002/v1; setting up OpenCode and Hermes for it.")
    }

    @Test("the pair's API: its models are named (your pair), and the names stay the same on every run")
    func aPairsModelsAreThePairs() async throws {
        let keyFile = URL(fileURLWithPath: "/tmp/fixture/local_token")
        let info = LocalEndpoint.Info(host: "0.0.0.0", port: 8001, apiKey: "dk-local-fixture", version: "t", pid: 41,
                                      updatedAt: "")
        #expect(IntegrationEndpoint.live(info, keyFile: { _ in keyFile }, pairProcesses: { [41, 40] })?.servesThePair
                == true, "this Mac's running part of the pair serves it")
        #expect(IntegrationEndpoint.live(info, keyFile: { _ in keyFile }, pairProcesses: { [7] })?.servesThePair == false)
        #expect(IntegrationEndpoint.live(info, keyFile: { _ in keyFile }, pairProcesses: { [] })?.servesThePair == false)
        // A member's relay writes local.json with its cluster service's pid: the pair's API too.
        let relay = LocalEndpoint.Info(host: "0.0.0.0", port: 8001, apiKey: "dk-local-fixture", version: "t", pid: 40,
                                       updatedAt: "")
        #expect(IntegrationEndpoint.live(relay, keyFile: { _ in keyFile }, pairProcesses: { [41, 40] })?.servesThePair
                == true, "the relay serves the pair")

        let sandbox = try WordsSandbox()
        let first = await sandbox.run([.opencode, .hermes], pair: true)
        #expect(first.contains("  New Hermes chats now use Darkbloom's Qwen 3.8 27B. Switch back: hermes model"))
        let openCode = try Data(contentsOf: sandbox.openCodeJSONC)
        let hermes = try Data(contentsOf: sandbox.hermesFile)
        #expect(F.utf8(openCode).contains("\"name\": \"Qwen 3.8 27B (your pair)\""))
        #expect(!F.utf8(openCode).contains("this Mac"))
        #expect(F.utf8(hermes).contains("  default: \"\(WordsSandbox.qwen)\""), "the pair's model is the main one")
        // Again, online and offline: nothing changes.
        for catalog in [WordsSandbox.catalog, nil] as [CatalogSnapshot?] {
            let again = await sandbox.run([.opencode, .hermes], pair: true, catalog: catalog)
            #expect(again.prefix(2) == ["✓ OpenCode already lists Darkbloom's 1 model (nothing changed).",
                                        "✓ Hermes already uses Darkbloom's current models (nothing changed)."])
            #expect(try Data(contentsOf: sandbox.openCodeJSONC) == openCode && Data(contentsOf: sandbox.hermesFile) == hermes)
        }
    }

    @Test("the pair's processes: its part's, and its cluster service's, whose relay serves a member's API")
    func thePairsProcesses() {
        var status = ClusterServiceStatus(role: "follower", serving: true, modelName: "m", sessionLeader: false,
                                          localRank: 1, setup: nil, child: .init(running: true, starts: 1, pid: 41),
                                          session: nil)
        status.servicePID = 40
        #expect(ClusterPairSummary.pairProcesses(of: status) == [41, 40])
        status.child.running = false
        #expect(ClusterPairSummary.pairProcesses(of: status).isEmpty, "no part runs: no pair serves here")
        #expect(ClusterPairSummary.pairProcesses(of: nil).isEmpty, "no cluster service")
    }

    // MARK: - Every line an edit can give

    @Test("each way an edit can go has its own Changed: words, and OpenCode's default its own line")
    func everyChangedAndDefaultLine() {
        func changed(_ tool: IntegrationTool, _ change: ToolConfigSummary.ProviderChange, setsDefault: Bool,
                     newFile: Bool = false) -> String {
            let summary = ToolConfigSummary(provider: change, models: ["m"],
                                            defaultModel: setsDefault ? "darkbloom/m" : nil)
            return ToolIntegrationStep.changed(tool, summary, newFile: newFile, provider: F.provider)
        }
        let block = "the \"darkbloom\" provider"
        #expect(changed(.opencode, .added, setsDefault: true, newFile: true)
            == "a new file with \(block) and the default model")
        #expect(changed(.opencode, .added, setsDefault: false, newFile: true) == "a new file with \(block)")
        #expect(changed(.opencode, .added, setsDefault: true)
            == "added \(block) and the default model; nothing else changed")
        #expect(changed(.opencode, .added, setsDefault: false) == "added \(block); nothing else changed")
        #expect(changed(.opencode, .updated, setsDefault: true)
            == "updated \(block) and the default model; nothing else changed")
        #expect(changed(.opencode, .updated, setsDefault: false) == "updated \(block); nothing else changed")
        #expect(changed(.opencode, .unchanged, setsDefault: true) == "added the default model; nothing else changed")
        #expect(changed(.hermes, .added, setsDefault: true, newFile: true)
            == "a new file with \(block) as the main model")
        #expect(changed(.hermes, .added, setsDefault: true) == "added \(block) and made it the main model")
        #expect(changed(.hermes, .updated, setsDefault: true) == "updated \(block) and made it the main model")
        #expect(changed(.hermes, .unchanged, setsDefault: true) == "made \(block) the main model")

        let pair = [IntegrationModel(id: "m", name: "Qwen 3.8 27B (your pair)", location: .yourPair,
                                     contextLength: 262_144, outputLimit: 65_536, tools: true, imageInput: false,
                                     reasoning: false)]
        func line(_ defaultModel: String?, kept: String? = nil, remembered: String? = nil) -> String {
            var summary = ToolConfigSummary(provider: .added, models: ["m"], defaultModel: defaultModel,
                                            keptDefault: kept)
            summary.rememberedPick = remembered
            return ToolIntegrationStep.openCodeDefault(summary, models: pair, provider: F.provider,
                                                       file: "~/.config/opencode/opencode.json")
        }
        #expect(line("darkbloom/m") == "New OpenCode sessions now use Darkbloom's Qwen 3.8 27B. To go back, remove "
            + "\"model\" from ~/.config/opencode/opencode.json or run the Undo below.")
        #expect(line(nil, kept: "exo/llama-3.3-70b")
            == "Your default stays exo/llama-3.3-70b; pick Darkbloom with /models.")
        #expect(line(nil, kept: "darkbloom/m")
            == "Your default stays darkbloom/m (the \"model\" in your OpenCode config).")
        #expect(line(nil, remembered: "omlx/qwen3.6") == "Pick Darkbloom once with /models; OpenCode remembers it.")
        #expect(line(nil) == "Your default model stays as your config sets it; pick Darkbloom with /models.")
    }
}
