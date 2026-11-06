import Foundation
import Testing

@testable import darkbloom

private typealias F = ToolIntegrationFixtures

private func plan(_ existing: String?, models: [IntegrationModel] = F.models) -> ToolConfigPlan {
    HermesConfigPlan.plan(existing: existing.map { Data($0.utf8) }, endpoint: F.endpoint, models: models,
                          provider: F.provider)
}

/// The `darkbloom` provider block for `F.models` at a two-space child indent, without the comment line above it.
private let block = """
  darkbloom:
    name: "Darkbloom"
    api: "http://127.0.0.1:8123/v1"
    transport: "chat_completions"
    key_cmd: "/bin/cat /Users/tester/.darkbloom/local_token"
    default_model: "qwen3.8-27b"
    extra_body:
      max_tokens: 24576
    models:
      "qwen3.8-27b":
        context_length: 131072
      "glm-5.3-flash":
        context_length: 98304
        supports_vision: true

"""

private let added = "  # Added by `darkbloom start --hermes`. Run it again to refresh Darkbloom's models.\n"

private let mainModel = """
model:
  provider: "custom:darkbloom"
  default: "qwen3.8-27b"

"""

/// Every key Darkbloom writes under `providers.<name>`, from Hermes' list of the keys an entry accepts
/// (https://hermes-agent.nousresearch.com/docs/integrations/providers, "Named Custom Providers"), and under
/// `models.<id>` (`context_length`; `supports_vision`, documented on the same page under "Native vision for
/// custom-provider models").
private let documentedProviderKeys: Set<String> = [
    "api", "name", "key_cmd", "transport", "default_model", "models", "extra_body",
]
private let documentedModelKeys: Set<String> = ["context_length", "supports_vision"]

@Suite("Hermes config plan")
struct HermesConfigPlanTests {
    @Test("no file: the provider block and the main model")
    func createsTheFile() throws {
        let result = plan(nil)
        #expect(F.newText(result) == "providers:\n" + added + block + mainModel)
        #expect(F.summary(result) == ToolConfigSummary(
            provider: .added, models: ["qwen3.8-27b", "glm-5.3-flash"], defaultModel: "qwen3.8-27b",
            leftOut: ["gemma-4-26b-qat-4bit"]))
        let text = try #require(F.newText(result))
        #expect(plan(text) == .unchanged(ToolConfigSummary(
            provider: .unchanged, models: ["qwen3.8-27b", "glm-5.3-flash"], defaultModel: "qwen3.8-27b",
            leftOut: ["gemma-4-26b-qat-4bit"])))
    }

    @Test("every key written is one Hermes documents")
    func documentedKeys() throws {
        let text = try #require(F.newText(plan(nil)))
        let lines = text.split(separator: "\n").map(String.init)
        let start = try #require(lines.firstIndex(of: "  darkbloom:"))
        let end = try #require(lines.firstIndex(of: "model:"))
        for line in lines[(start + 1)..<end] {
            let indent = line.prefix { $0 == " " }.count
            let key = line.drop { $0 == " " }.prefix { $0 != ":" }
            switch indent {
            case 4: #expect(documentedProviderKeys.contains(String(key)), "\(line)")
            case 8: #expect(documentedModelKeys.contains(String(key)), "\(line)")
            default: break
            }
        }
    }

    @Test("Hermes' fresh-install model sentinel is replaced by the main model mapping")
    func freshInstallSentinel() {
        let result = plan("model: \"\"\ntoolsets:\n  - hermes-cli\n")
        #expect(F.newText(result) == mainModel + "toolsets:\n  - hermes-cli\nproviders:\n" + added + block)
    }

    @Test("a file as oMLX writes it: its provider stays byte for byte, the old endpoint pins go, the rest stays")
    func omlxSetup() throws {
        let omlxProvider = """
          # oMLX on port 8000
          omlx:
            name: oMLX
            api: http://127.0.0.1:8000/v1
            api_key: omlx-local-key
            models:
              Qwen3.6-35B-A3B-4bit:
                context_length: 262144

        """
        let owner = """
        # Hermes config, edited by hand.
        model:
          provider: omlx  # set by omlx launch
          default: Qwen3.6-35B-A3B-4bit
          base_url: http://127.0.0.1:8000/v1
          context_length: 262144
          max_tokens: 32768
          switch_context_confirm_tokens: 100000
        providers:

        """ + omlxProvider + """

        toolsets:
          - hermes-cli

        """
        let result = plan(owner)
        let text = try #require(F.newText(result))
        #expect(text == """
        # Hermes config, edited by hand.
        model:
          provider: "custom:darkbloom"
          default: "qwen3.8-27b"
          switch_context_confirm_tokens: 100000
        providers:

        """ + omlxProvider + added + block + """

        toolsets:
          - hermes-cli

        """)
        #expect(F.summary(result)?.droppedComments == 1)
        #expect(F.summary(result)?.provider == .added)
        #expect(plan(text) == .unchanged(ToolConfigSummary(
            provider: .unchanged, models: ["qwen3.8-27b", "glm-5.3-flash"], defaultModel: "qwen3.8-27b",
            leftOut: ["gemma-4-26b-qat-4bit"])))
    }

    @Test("the model: alias key is set in place, and no default key is added")
    func modelAliasKey() {
        let owner = "model:\n  model: openrouter/some-model\n  provider: openrouter\n"
        #expect(F.newText(plan(owner)) == """
        model:
          model: "qwen3.8-27b"
          provider: "custom:darkbloom"
        providers:

        """ + added + block)
    }

    @Test("a Darkbloom default that is still listed with 64K or more is kept")
    func keepsTheCurrentDefault() throws {
        let created = try #require(F.newText(plan(nil)))
        let switched = created.replacingOccurrences(of: "  default: \"qwen3.8-27b\"", with: "  default: \"glm-5.3-flash\"")
        let result = plan(switched)
        let text = try #require(F.newText(result))
        #expect(text.contains("  default: \"glm-5.3-flash\"\n"))
        #expect(text.contains("    default_model: \"glm-5.3-flash\"\n"))
        #expect(F.summary(result)?.defaultModel == "glm-5.3-flash")
        // Another tool's model of the same name doesn't count as Darkbloom's.
        let foreign = "model:\n  provider: ollama\n  default: glm-5.3-flash\n"
        #expect(F.summary(plan(foreign))?.defaultModel == "qwen3.8-27b")
    }

    @Test("an old darkbloom block is replaced whole; other providers, comments and blank lines stay")
    func replacesTheOldBlock() throws {
        let owner = """
        providers:
          # Added by `darkbloom start --hermes`. Run it again to refresh Darkbloom's models.
          darkbloom:
            name: "Darkbloom"
            api: "http://127.0.0.1:8000/v1"
            # an old note inside the block
            models:
              "old-model":
                context_length: 65536

          ollama-launch:
            api: http://127.0.0.1:11434/v1
        model:
          provider: "custom:darkbloom"
          default: "old-model"

        """
        let result = plan(owner)
        #expect(F.newText(result) == "providers:\n" + added + block + """

          ollama-launch:
            api: http://127.0.0.1:11434/v1

        """ + mainModel)
        #expect(F.summary(result)?.provider == .updated)
        #expect(F.summary(result)?.droppedComments == 1)
    }

    @Test("Hermes' 64K floor: no model with at least 64,000 tokens of context refuses, naming the largest")
    func contextFloor() {
        let refusal = F.refusal(plan(nil, models: [F.gemma]))
        #expect(refusal?.kind == .models)
        #expect(refusal?.reason
            == "Hermes needs a model with at least 64K context. Darkbloom's models here offer at most 32K now; OpenCode can use them.")
        let unknown = IntegrationModel(id: "m", name: "m (this Mac)", location: .thisMac, contextLength: nil,
                                       outputLimit: nil, tools: true, imageInput: false, reasoning: false)
        #expect(F.refusal(plan(nil, models: [unknown]))?.kind == .models)
        // Exactly 64,000 is enough, as for Hermes itself.
        let edge = IntegrationModel(id: "edge", name: "Edge (this Mac)", location: .thisMac, contextLength: 64_000,
                                    outputLimit: 16_000, tools: true, imageInput: false, reasoning: false)
        #expect(F.summary(plan(nil, models: [edge]))?.defaultModel == "edge")
        // A network model can be listed but is never the main model.
        let network = IntegrationModel(id: "net", name: "Net (Darkbloom network, billed)", location: .network,
                                       contextLength: 131_072, outputLimit: 32_768, tools: true, imageInput: false,
                                       reasoning: false)
        #expect(F.refusal(plan(nil, models: [network]))?.kind == .models)
        #expect(F.summary(plan(nil, models: [network, F.glm]))?.defaultModel == "glm-5.3-flash")
    }

    @Test("model IDs with /, : and quotes round-trip through the emitter")
    func quoting() throws {
        let odd = IntegrationModel(id: "mlx-community/Qwen3.6:35b \"q\\4\"", name: "x (this Mac)", location: .thisMac,
                                   contextLength: 65_536, outputLimit: 16_384, tools: true, imageInput: false,
                                   reasoning: false)
        let text = try #require(F.newText(plan(nil, models: [odd])))
        #expect(text.contains("      \"mlx-community/Qwen3.6:35b \\\"q\\\\4\\\"\":\n"))
        #expect(text.contains("  default: \"mlx-community/Qwen3.6:35b \\\"q\\\\4\\\"\"\n"))
        #expect(plan(text, models: [odd]) == .unchanged(ToolConfigSummary(
            provider: .unchanged, models: [odd.id], defaultModel: odd.id)))
    }

    @Test("a key file path with a space is quoted for the shell inside key_cmd")
    func keyCommandQuoting() throws {
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8002/v1",
                                           keyFile: URL(fileURLWithPath: "/Users/te ster/.darkbloom-dev/local_token"))
        let result = HermesConfigPlan.plan(existing: nil, endpoint: endpoint, models: [F.qwen], provider: F.provider)
        #expect(F.newText(result)?.contains("    key_cmd: \"/bin/cat '/Users/te ster/.darkbloom-dev/local_token'\"\n")
            == true)
    }

    @Test("refusals: several documents, anchors or aliases, flow or block-scalar sections, tabs, a non-mapping root")
    func refusals() {
        let cases = [
            "model: x\n---\nother: y\n",
            "model: &main\n  default: x\n",
            "model:\n  default: *main\n",
            "model:\n  <<: *base\n  default: x\n",
            "providers: {omlx: {api: x}}\n",
            "providers:\n  omlx: {api: x,\n    name: y}\n",
            "model: |\n  some text\n",
            "model:\n\tdefault: x\n",
            "- a\n- b\n",
            "providers:\n  omlx:\n    api: x\nproviders:\n  other:\n    api: y\n",
            "model: \"x\n  y\"\n",
        ]
        for text in cases {
            #expect(F.refusal(plan(text))?.kind == .file, "\(text)")
        }
        // A single leading document marker and an empty providers mapping are fine.
        #expect(F.newText(plan("---\nproviders: {}\n")) == "---\nproviders:\n" + added + block + mainModel)
    }

    @Test("the config file: $HERMES_HOME/config.yaml, else ~/.hermes/config.yaml")
    func configFile() {
        #expect(HermesConfigPlan.configFile(home: F.home, variables: [:]).path == "/Users/tester/.hermes/config.yaml")
        #expect(HermesConfigPlan.configFile(home: F.home, variables: ["HERMES_HOME": "/tmp/h"]).path
            == "/tmp/h/config.yaml")
        #expect(HermesConfigPlan.configFile(home: F.home, variables: ["HERMES_HOME": ""]).path
            == "/Users/tester/.hermes/config.yaml")
    }
}
