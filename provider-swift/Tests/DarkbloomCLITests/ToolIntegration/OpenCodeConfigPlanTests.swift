import Foundation
import Testing

@testable import darkbloom

private typealias F = ToolIntegrationFixtures

private func plan(_ existing: String?, fileName: String = "opencode.jsonc",
                  models: [IntegrationModel] = F.models,
                  endpoint: IntegrationEndpoint = F.endpoint) -> ToolConfigPlan {
    OpenCodeConfigPlan.plan(existing: existing.map { Data($0.utf8) }, fileName: fileName, endpoint: endpoint,
                            models: models, provider: F.provider, home: F.home)
}

/// The `darkbloom` value as the planner renders it for `F.models`, with each line after the first indented by
/// `indent`.
private func darkbloomValue(indent: String) -> String {
    """
    {
      "name": "Darkbloom",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://127.0.0.1:8123/v1",
        "apiKey": "{file:~/.darkbloom/local_token}"
      },
      "compatibility": { "maxTokensField": "max_tokens" },
      "models": {
        "gemma-4-26b-qat-4bit": {
          "name": "Gemma 4 26B QAT (this Mac)",
          "limit": { "context": 32768, "output": 8192 },
          "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"] }
        },
        "qwen3.8-27b": {
          "name": "Qwen 3.8 27B (this Mac)",
          "limit": { "context": 131072, "output": 32768 },
          "capabilities": { "tools": true, "input": ["text"], "output": ["text"], "reasoning": { "supported": true } }
        },
        "glm-5.3-flash": {
          "name": "GLM-5.3-Flash (your Macs)",
          "limit": { "context": 98304, "output": 24576 },
          "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"], "reasoning": { "supported": true } }
        }
      }
    }
    """.replacingOccurrences(of: "\n", with: "\n" + indent)
}

private let addedComment = "// Added by `darkbloom start --opencode`. Run it again to refresh Darkbloom's models."

@Suite("OpenCode config plan")
struct OpenCodeConfigPlanTests {
    @Test("no file: a new opencode.jsonc with the schema, the default model and the provider")
    func createsTheFile() throws {
        let result = plan(nil)
        let text = try #require(F.newText(result))
        #expect(text == """
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "darkbloom/gemma-4-26b-qat-4bit",
          "providers": {
            \(addedComment)
            "darkbloom": \(darkbloomValue(indent: "    "))
          }
        }

        """)
        #expect(F.summary(result) == ToolConfigSummary(
            provider: .added, models: ["gemma-4-26b-qat-4bit", "qwen3.8-27b", "glm-5.3-flash"],
            defaultModel: "darkbloom/gemma-4-26b-qat-4bit"))
        #expect(plan(text) == .unchanged(ToolConfigSummary(
            provider: .unchanged, models: ["gemma-4-26b-qat-4bit", "qwen3.8-27b", "glm-5.3-flash"],
            defaultModel: nil)))
    }

    @Test("an owner's file: only the providers block grows; comments, trailing commas, others and the model stay")
    func updatesInPlace() throws {
        let prefix = """
        {
          "$schema": "https://opencode.ai/config.json",
          // Owner's own comment that must survive.
          "model": "anthropic/claude-sonnet-5-5",
          /* A block comment, also kept. */
          "provider": { "omlx": { "npm": "@ai-sdk/openai-compatible", "options": { "baseURL": "http://127.0.0.1:8000/v1" } } },
          "providers": {
            "lmstudio": { "name": "LM Studio", }, // a trailing comma inside

        """
        let suffix = """
          },
        }

        """
        let owner = prefix + suffix
        let result = plan(owner)
        let text = try #require(F.newText(result))
        #expect(text == prefix + """
            \(addedComment)
            "darkbloom": \(darkbloomValue(indent: "    ")),

        """ + suffix)
        #expect(F.summary(result)?.provider == .added)
        #expect(F.summary(result)?.defaultModel == nil)
        #expect(F.summary(result)?.droppedComments == 0)

        // The same run again changes nothing.
        #expect(plan(text) == .unchanged(ToolConfigSummary(
            provider: .unchanged, models: ["gemma-4-26b-qat-4bit", "qwen3.8-27b", "glm-5.3-flash"],
            defaultModel: nil)))

        // A changed model list rewrites only the models member.
        let fewer = plan(text, models: [F.qwen])
        let rewritten = try #require(F.newText(fewer))
        let modelsKey = "      \"models\": {"
        let before = try #require(text.range(of: modelsKey))
        let after = try #require(rewritten.range(of: modelsKey))
        #expect(text[..<before.lowerBound] == rewritten[..<after.lowerBound])
        let tail = "\n      }\n    },\n" + suffix
        #expect(text.hasSuffix(tail) && rewritten.hasSuffix(tail))
        #expect(rewritten.contains("\"qwen3.8-27b\"") && !rewritten.contains("gemma"))
        #expect(F.summary(fewer) == ToolConfigSummary(provider: .updated, models: ["qwen3.8-27b"], defaultModel: nil))
    }

    @Test("a strict .json file gets no comment and stays strict JSON")
    func strictJSON() throws {
        let owner = """
        {
          "model": "openai/gpt-5",
          "theme": "dark"
        }

        """
        let text = try #require(F.newText(plan(owner, fileName: "opencode.json")))
        #expect(!text.contains("// Added by"))
        #expect(text.hasPrefix("{\n  \"model\": \"openai/gpt-5\",\n  \"theme\": \"dark\",\n  \"providers\": {\n"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(parsed["model"] as? String == "openai/gpt-5")
        let providers = try #require(parsed["providers"] as? [String: Any])
        let darkbloom = try #require(providers["darkbloom"] as? [String: Any])
        let settings = try #require(darkbloom["settings"] as? [String: Any])
        #expect(settings["baseURL"] as? String == "http://127.0.0.1:8123/v1")
        #expect(settings["apiKey"] as? String == "{file:~/.darkbloom/local_token}")
        #expect((darkbloom["compatibility"] as? [String: String])?["maxTokensField"] == "max_tokens")
        #expect((darkbloom["models"] as? [String: Any])?.count == 3)
        #expect(darkbloom["headers"] == nil)
    }

    @Test("an owner's V1 provider block stays byte for byte; providers is added beside it")
    func keepsTheV1Block() throws {
        let v1 = """
        {
          "provider": {
            "omlx": { "npm": "@ai-sdk/openai-compatible", "options": { "baseURL": "http://127.0.0.1:8000/v1" } }
          }
        """
        let text = try #require(F.newText(plan(v1 + "\n}\n", fileName: "opencode.json")))
        #expect(text.hasPrefix(v1 + ",\n  \"model\": \"darkbloom/gemma-4-26b-qat-4bit\",\n  \"providers\": {\n"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((parsed["provider"] as? [String: Any])?["omlx"] != nil)
        #expect((parsed["providers"] as? [String: Any])?["darkbloom"] != nil)
    }

    @Test("a default model the owner set is kept; none set means Darkbloom's first model")
    func defaultModel() throws {
        let kept = try #require(F.newText(plan("{\n  \"model\": \"\"\n}\n")))
        #expect(kept.hasPrefix("{\n  \"model\": \"\",\n  \"providers\": {"))
        let set = plan("{\n  \"theme\": \"dark\"\n}\n")
        #expect(F.newText(set)?.contains("  \"model\": \"darkbloom/gemma-4-26b-qat-4bit\",\n") == true)
        #expect(F.summary(set)?.defaultModel == "darkbloom/gemma-4-26b-qat-4bit")
    }

    @Test("a default model set in another global file means none is added here, to a new file either")
    func defaultModelSetElsewhere() throws {
        let result = OpenCodeConfigPlan.plan(
            existing: Data("{\n  \"theme\": \"dark\"\n}\n".utf8), fileName: "opencode.jsonc", endpoint: F.endpoint,
            models: F.models, provider: F.provider, home: F.home, defaultModelElsewhere: true)
        let text = try #require(F.newText(result))
        #expect(!text.contains("\"model\""))
        #expect(F.summary(result)?.defaultModel == nil)
        let created = OpenCodeConfigPlan.plan(
            existing: nil, fileName: "opencode.jsonc", endpoint: F.endpoint, models: F.models, provider: F.provider,
            home: F.home, defaultModelElsewhere: true)
        #expect(F.newText(created)?.contains("\"model\"") == false)
    }

    @Test("another global file sets a default: its own top-level model key, or it can't be read")
    func otherGlobalConfigSetsModel() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.file("opencode")
        let jsonc = folder.appendingPathComponent("opencode.jsonc")
        #expect(!OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: jsonc))
        try directory.write("{\n  \"theme\": \"dark\"\n}\n", to: "opencode/opencode.json")
        #expect(!OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: jsonc))
        try directory.write("{ \"agent\": { \"build\": { \"model\": \"x/y\" } } }", to: "opencode/opencode.json")
        #expect(!OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: jsonc))
        try directory.write("{\n  // mine\n  \"model\": \"omlx/q\",\n}\n", to: "opencode/opencode.json")
        #expect(OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: jsonc))
        try directory.write("{ \"model\": ", to: "opencode/opencode.json")
        #expect(OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: jsonc))
        // The file being edited isn't another one: its own model is the planner's to read.
        #expect(!OpenCodeConfigPlan.otherGlobalConfigSetsModel(besides: folder.appendingPathComponent("opencode.json")))
    }

    @Test("an empty object and a one-line object get the provider on their own lines")
    func compactObjects() throws {
        let empty = try #require(F.newText(plan("{}", fileName: "opencode.json")))
        #expect(empty.hasPrefix("{\n  \"model\": \"darkbloom/gemma-4-26b-qat-4bit\",\n  \"providers\": {\n"))
        #expect(empty.hasSuffix("\n  }\n}"))
        let oneLine = try #require(F.newText(plan("{\"theme\": \"dark\"}\n", fileName: "opencode.json")))
        #expect(oneLine.hasPrefix("{\"theme\": \"dark\",\n  \"model\": "))
        for text in [empty, oneLine] {
            #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil)
        }
    }

    @Test("Windows line breaks stay on every line, the added ones included, and a re-run changes nothing")
    func crlfLineBreaks() throws {
        let text = try #require(F.newText(plan("{\r\n  // mine\r\n  \"model\": \"x/y\"\r\n}\r\n")))
        #expect(text.hasPrefix("{\r\n  // mine\r\n  \"model\": \"x/y\",\r\n  \"providers\": {\r\n"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(F.summary(plan(text))?.provider == .unchanged)
        #expect(F.newText(plan(text)) == nil)
    }

    @Test("an old darkbloom value is replaced whole, and its comments are counted as gone")
    func replacesTheOldValue() throws {
        let owner = """
        {
          "model": "x/y",
          "providers": {
            "darkbloom": { /* stale */ "name": "Old" }
          }
        }

        """
        let result = plan(owner)
        let text = try #require(F.newText(result))
        #expect(text == """
        {
          "model": "x/y",
          "providers": {
            "darkbloom": \(darkbloomValue(indent: "    "))
          }
        }

        """)
        #expect(F.summary(result)?.provider == .updated)
        #expect(F.summary(result)?.droppedComments == 1)
        #expect(F.summary(result)?.droppedCommentsNote
            == "1 comment on the lines Darkbloom replaced is gone; the backup keeps it.")
    }

    @Test("the key file is referenced, under ~ when it is in the home directory, else by its absolute path")
    func keyFileReference() throws {
        let outside = IntegrationEndpoint(baseURL: "http://192.168.1.20:8001/v1",
                                          keyFile: URL(fileURLWithPath: "/opt/darkbloom/cluster_local_token"))
        let text = try #require(F.newText(plan(nil, endpoint: outside)))
        #expect(text.contains("\"apiKey\": \"{file:/opt/darkbloom/cluster_local_token}\""))
        #expect(text.contains("\"baseURL\": \"http://192.168.1.20:8001/v1\""))
        #expect(!text.contains("8000"))
    }

    @Test("names, order and capabilities come from the models; no headers or route are ever written")
    func modelEntries() throws {
        let network = IntegrationModel(
            id: "minimax-m3", name: "MiniMax M3 (Darkbloom network, billed)", location: .network,
            contextLength: nil, outputLimit: nil, tools: false, imageInput: false, reasoning: false)
        let text = try #require(F.newText(plan(nil, models: [F.qwen, network])))
        #expect(text.contains("""
                "minimax-m3": {
                  "name": "MiniMax M3 (Darkbloom network, billed)",
                  "capabilities": { "tools": false, "input": ["text"], "output": ["text"] }
                }
        """))
        #expect(text.range(of: "qwen3.8-27b\": {")!.lowerBound < text.range(of: "minimax-m3\": {")!.lowerBound)
        #expect(!text.contains("headers"))
        #expect(!text.contains("X-Darkbloom-Route"))
        #expect(!text.contains("variants") && !text.contains("cost"))
    }

    @Test("model IDs and names are escaped as JSON strings")
    func escaping() throws {
        let odd = IntegrationModel(
            id: "org/model:\"q\\4\"", name: "Odd \"one\" (this Mac)", location: .thisMac,
            contextLength: 65_536, outputLimit: 16_384, tools: true, imageInput: false, reasoning: false)
        let text = try #require(F.newText(plan("{}", fileName: "opencode.json", models: [odd])))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let models = (((parsed["providers"] as? [String: Any])?["darkbloom"] as? [String: Any])?["models"]
            as? [String: Any])
        #expect((models?["org/model:\"q\\4\""] as? [String: Any])?["name"] as? String == "Odd \"one\" (this Mac)")
        #expect(parsed["model"] as? String == "darkbloom/org/model:\"q\\4\"")
    }

    @Test("refusals: not an object, providers not an object, malformed or ambiguous; nothing is planned")
    func refusals() {
        let cases: [(String, String)] = [
            ("[]", "isn't a JSON object"),
            ("\"text\"", "isn't a JSON object"),
            ("{\"providers\": []}", "\"providers\" isn't an object"),
            ("{\"providers\": null}", "\"providers\" isn't an object"),
            ("{\n  \"model\": \"x\n}", "isn't valid JSON (line 2)"),
            ("{\n  /* never closed\n}", "isn't valid JSON (line 2)"),
            ("{\"a\": 1} x", "isn't valid JSON (line 1)"),
            ("{\"a\": 1,, \"b\": 2}", "isn't valid JSON (line 1)"),
            ("{\"providers\": {}, \"providers\": {}}", "has two \"providers\" keys"),
            ("{\"providers\": {\"darkbloom\": {}, \"darkbloom\": {}}}", "has two \"darkbloom\" providers"),
        ]
        for (text, reason) in cases {
            let refusal = F.refusal(plan(text))
            #expect(refusal?.kind == .file, "\(text)")
            #expect(refusal?.reason.contains(reason) == true, "\(text): \(String(describing: refusal))")
        }
        #expect(F.refusal(plan("{}", models: []))?.kind == .models)
    }

    @Test("the config file: XDG_CONFIG_HOME or ~/.config; the last existing of .json and .jsonc, else a new .jsonc")
    func configFile() throws {
        let directory = try TemporaryDirectory()
        let home = directory.file("home")
        let xdg = directory.file("xdg")
        func chosen(_ variables: [String: String]) -> String {
            OpenCodeConfigPlan.configFile(home: home, variables: variables).path
        }
        #expect(chosen([:]) == home.path + "/.config/opencode/opencode.jsonc")
        #expect(chosen(["XDG_CONFIG_HOME": xdg.path]) == xdg.path + "/opencode/opencode.jsonc")
        #expect(chosen(["XDG_CONFIG_HOME": ""]) == home.path + "/.config/opencode/opencode.jsonc")
        try directory.write("{}", to: "home/.config/opencode/opencode.json")
        #expect(chosen([:]) == home.path + "/.config/opencode/opencode.json")
        try directory.write("{}", to: "home/.config/opencode/opencode.jsonc")
        #expect(chosen([:]) == home.path + "/.config/opencode/opencode.jsonc")
    }
}
