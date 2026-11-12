import Foundation
import Testing

@testable import ProviderCore

/// The `$ref` fixtures are the coordinator's, copied byte for byte into
/// `Fixtures/toolschema-refs/` from darkbloom-platform
/// coordinator/tests/api/inference/request/testdata/toolschema_refs/
/// (TOOLSCHEMA-REF): `want` is the tools after `$ref` resolution, and
/// `want_repaired` that plus the render-safe repair. The local API must
/// resolve exactly as the coordinator does for routed requests.
private enum RefFixture {
    static func object(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
            subdirectory: "Fixtures/toolschema-refs"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// One JSON form for comparing values: sorted keys, no spaces.
    static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["v": value], options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    static func mode(_ name: String) throws -> ToolSchemaRefMode {
        try #require(ToolSchemaRefMode(rawValue: name))
    }

    static func stats(_ raw: Any?) throws -> ToolSchemaRefStats {
        let dict = try #require(raw as? [String: Int])
        return ToolSchemaRefStats(
            refs: dict["refs"] ?? -1, inlined: dict["inlined"] ?? -1, keptCyclic: dict["kept_cyclic"] ?? -1,
            keptUnresolved: dict["kept_unresolved"] ?? -1, keptBounds: dict["kept_bounds"] ?? -1,
            typed: dict["typed"] ?? -1, off: dict["off"] ?? -1)
    }

    /// The generated request of the large cases (make_fixtures.py's request_of).
    static func generated(_ spec: [String: Any]) throws -> [Any] {
        let count = try #require(spec["count"] as? Int)
        let size = try #require(spec["enum_size"] as? Int)
        let enumValues = (0..<size).map(String.init).joined(separator: ",")
        let tools = (0..<count).map { index in
            ##"{"type":"function","function":{"name":"t\##(index)","description":"d","parameters":"##
                + ##"{"type":"object","properties":{"v":{"$ref":"#/$defs/Big"}},"$defs":{"Big":{"enum":["##
                + enumValues + "]}}}}}"
        }
        let data = Data(("[" + tools.joined(separator: ",") + "]").utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
    }

    /// The render-safe repair applied to every schema home, as the coordinator
    /// does after resolution (`normalizeToolEntry`).
    static func repaired(_ tools: [Any]) -> [Any] {
        tools.map { tool -> Any in
            guard var dict = tool as? [String: Any] else { return tool }
            if var function = dict["function"] as? [String: Any] {
                if let parameters = function["parameters"] {
                    function["parameters"] = ToolSchemaNormalization.injectDefaultTypes(parameters)
                }
                dict["function"] = function
            } else if let parameters = dict["parameters"] {
                dict["parameters"] = ToolSchemaNormalization.injectDefaultTypes(parameters)
            }
            if let schema = dict["input_schema"] {
                dict["input_schema"] = ToolSchemaNormalization.injectDefaultTypes(schema)
            }
            return dict
        }
    }

    static func hasRefs(_ value: Any) throws -> Bool { try canonical(value).contains(#""$ref""#) }
}

@Suite("Tool schema $ref resolution (shared fixtures)")
struct ToolSchemaRefResolutionTests {

    @Test func everySharedCaseResolvesLikeTheCoordinator() throws {
        let fixture = try RefFixture.object("toolschema_refs_cases")
        let bounds = try #require(fixture["bounds"] as? [String: Int])
        #expect(bounds["max_nodes"] == ToolSchemaRefResolution.maxNodes)
        #expect(bounds["max_depth"] == ToolSchemaRefResolution.maxDepth)
        #expect(bounds["max_request_nodes"] == ToolSchemaRefResolution.maxRequestNodes)
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        #expect(cases.count >= 45)
        for testCase in cases {
            let name = try #require(testCase["name"] as? String)
            let mode = try RefFixture.mode(try #require(testCase["mode"] as? String))
            var tools: [Any]
            if let generator = testCase["tools_generator"] as? [String: Any] {
                tools = try RefFixture.generated(generator)
            } else {
                tools = try #require(testCase["tools"] as? [Any], "\(name)")
            }
            let stats = ToolSchemaRefResolution.resolve(&tools, mode: mode)
            let wantStats = try RefFixture.stats(testCase["want_stats"])
            #expect(stats == wantStats, "\(name)")
            if testCase["tools_generator"] != nil {
                let allInlined = testCase["want_all_inlined"] as? Bool ?? false
                let noneInlined = testCase["want_none_inlined"] as? Bool ?? false
                for tool in tools {
                    let refs = try RefFixture.hasRefs(tool)
                    #expect(!(allInlined && refs) && !(noneInlined && !refs), "\(name)")
                }
                continue
            }
            let want = try RefFixture.canonical(try #require(testCase["want"] as? [Any], "\(name)"))
            let wantRepaired = try RefFixture.canonical(try #require(testCase["want_repaired"] as? [Any], "\(name)"))
            let repaired = RefFixture.repaired(tools)
            let gotResolved = try RefFixture.canonical(tools)
            let gotRepaired = try RefFixture.canonical(repaired)
            #expect(gotResolved == want, "\(name): resolved")
            #expect(gotRepaired == wantRepaired, "\(name): repaired")
            // A fixed point: resolving the repaired tools again changes nothing.
            var again = repaired
            ToolSchemaRefResolution.resolve(&again, mode: mode)
            let gotAgain = try RefFixture.canonical(RefFixture.repaired(again))
            #expect(gotAgain == gotRepaired, "\(name): P1")
        }
    }

    /// The coordinator's forwarded declarations are a fixed point of the
    /// decode repair every provider version runs (`ensureParameterTypes`), so
    /// a routed body renders as the coordinator sent it.
    @Test func decodeRepairKeepsTheCoordinatorsDeclarations() throws {
        let airline = try RefFixture.object("toolschema_refs_tau2_airline")
        let modes = try #require(airline["modes"] as? [String: [String: Any]])
        for name in ["inline", "typed", "off"] {
            let forwarded = try #require(modes[name]?["want_repaired"] as? [Any])
            let body = try JSONSerialization.data(withJSONObject: ["model": "m", "tools": forwarded])
            let decoded = try #require(
                try JSONSerialization.jsonObject(with: ToolSchemaNormalization.ensureParameterTypes(in: body))
                    as? [String: Any])
            let got = try RefFixture.canonical(try #require(decoded["tools"]))
            let want = try RefFixture.canonical(forwarded)
            #expect(got == want, "\(name)")
        }
    }

    @Test func tau2AirlineToolsUnderEveryMode() throws {
        let airline = try RefFixture.object("toolschema_refs_tau2_airline")
        let raw = try #require(airline["tools"] as? [Any])
        let modes = try #require(airline["modes"] as? [String: [String: Any]])
        for name in ["inline", "typed", "off"] {
            let expected = try #require(modes[name])
            var tools = raw
            let stats = ToolSchemaRefResolution.resolve(&tools, mode: try RefFixture.mode(name))
            let wantStats = try RefFixture.stats(expected["want_stats"])
            let want = try RefFixture.canonical(try #require(expected["want"]))
            let wantRepaired = try RefFixture.canonical(try #require(expected["want_repaired"]))
            #expect(stats == wantStats, "\(name)")
            #expect(try RefFixture.canonical(tools) == want, "\(name)")
            #expect(try RefFixture.canonical(RefFixture.repaired(tools)) == wantRepaired, "\(name)")
        }
        // The 126 Tau2-shaped turns of the CPU A/B all carry these tools.
        let turns = try RefFixture.object("toolschema_refs_tau2_turns")
        let list = try #require(turns["turns"] as? [[String: Any]])
        #expect(list.count == 126)
        #expect(list.allSatisfy { $0["tools_sha256"] as? String == airline["tools_sha256"] as? String })
    }

    @Test func policyParsesTheCoordinatorsSyntax() {
        let def = ToolSchemaRefPolicy.default
        #expect(def.rules == [.init(pattern: "gemma-4-26b", mode: .inline), .init(pattern: "qwen3.8-27b", mode: .inline)])
        let cases: [(String?, [ToolSchemaRefPolicy.Rule], Bool)] = [
            (nil, def.rules, true),
            ("  ", def.rules, true),
            ("off", [], true),
            (" NONE ", [], true),
            (" Gemma-4-26B , gpt-oss-20b=typed , qwen3.8-27b=INLINE,",
             [.init(pattern: "gemma-4-26b", mode: .inline), .init(pattern: "gpt-oss-20b", mode: .typed),
              .init(pattern: "qwen3.8-27b", mode: .inline)], true),
            ("mimo = typed", [.init(pattern: "mimo", mode: .typed)], true),
            (",", def.rules, false),
            ("true", def.rules, false),
            ("0", def.rules, false),
            ("on", def.rules, false),
            ("gemma-4-26b,off", def.rules, false),
            ("=typed", def.rules, false),
            ("gemma-4-26b=full", def.rules, false),
        ]
        for (raw, rules, valid) in cases {
            let parsed = ToolSchemaRefPolicy.parse(raw)
            #expect(parsed.policy.rules == rules && parsed.valid == valid, "\(raw ?? "nil")")
        }
    }

    @Test func policySelectsPerModel() {
        let def = ToolSchemaRefPolicy.default
        let everything = ToolSchemaRefPolicy(rules: [
            .init(pattern: "gemma-4-26b-8bit", mode: .typed), .init(pattern: "-", mode: .inline),
            .init(pattern: "glm", mode: .inline), .init(pattern: "mimo", mode: .inline),
        ])
        let cases: [(ToolSchemaRefPolicy, String, String?, ToolSchemaRefMode)] = [
            (def, "gemma-4-26b-qat-4bit", "gemma4", .inline),
            (def, "gemma-4-26b-8bit", "gemma4", .inline),
            (def, "GEMMA-4-26B-QAT-4BIT", nil, .inline),
            (def, "EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5", .inline),
            (def, "gpt-oss-20b", "gpt_oss", .off),
            (def, "Qwen3.5-9B", "qwen3_5", .off),
            (def, "mimo-v2.6-flash-mopd", "mimo_v2", .off),
            (def, "", "gemma4", .off),
            (everything, "gemma-4-26b-8bit", "gemma4", .typed),
            (everything, "gpt-oss-20b", "gpt_oss", .inline),
            (everything, "glm-5.3-flash", "glm5_next", .off),
            (everything, "mimo-v2.6-flash-mopd", "mimo_v2", .typed),
            (ToolSchemaRefPolicy(rules: []), "gemma-4-26b-qat-4bit", "gemma4", .off),
        ]
        for (policy, model, type, want) in cases {
            #expect(policy.mode(forModel: model, modelType: type) == want, "\(model) \(type ?? "nil")")
        }
    }

    /// The local API resolves a body by its model's mode; other models, and
    /// bodies without `$ref`, keep their bytes.
    @Test func localAPIResolvesByModel() async throws {
        let airline = try RefFixture.object("toolschema_refs_tau2_airline")
        let raw = try #require(airline["tools"] as? [Any])
        let modes = try #require(airline["modes"] as? [String: [String: Any]])
        let modeFor: @Sendable (String) async -> ToolSchemaRefMode = { model in
            ToolSchemaRefPolicy.default.mode(forModel: model, modelType: nil)
        }
        func body(_ model: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "model": model, "messages": [["role": "user", "content": "hi"]], "tools": raw,
            ])
        }
        let gemma = try body("gemma-4-26b-qat-4bit")
        let resolved = await ToolSchemaRefResolution.resolveLocalBody(gemma, batch: false, modeFor: modeFor)
        let decoded = try #require(try JSONSerialization.jsonObject(with: resolved) as? [String: Any])
        let inlineWant = try RefFixture.canonical(try #require(modes["inline"]?["want"]))
        let gotTools = try RefFixture.canonical(try #require(decoded["tools"]))
        #expect(gotTools == inlineWant)

        let gpt = try body("gpt-oss-20b")
        let untouched = await ToolSchemaRefResolution.resolveLocalBody(gpt, batch: false, modeFor: modeFor)
        #expect(untouched == gpt)

        let batch = try JSONSerialization.data(withJSONObject: [
            try JSONSerialization.jsonObject(with: gemma), try JSONSerialization.jsonObject(with: gpt),
        ])
        let resolvedBatch = await ToolSchemaRefResolution.resolveLocalBody(batch, batch: true, modeFor: modeFor)
        let items = try #require(try JSONSerialization.jsonObject(with: resolvedBatch) as? [[String: Any]])
        let first = try RefFixture.canonical(try #require(items[0]["tools"]))
        let second = try RefFixture.canonical(try #require(items[1]["tools"]))
        #expect(first == inlineWant)
        #expect(try second == RefFixture.canonical(raw))
    }
}
