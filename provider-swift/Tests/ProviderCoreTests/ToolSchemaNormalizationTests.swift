import Foundation
import Testing

@testable import ProviderCore

private struct ToolSchemaFixtureCorpus: Decodable {
    let schemaVersion: Int?
    let cases: [ToolSchemaFixtureCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct ToolSchemaFixtureCase: Decodable {
    let name: String
    let mode: String
    let acceptance: String
    let input: JSONValue
    let normalized: JSONValue
}

private enum ToolSchemaFixtureError: Error {
    case missingSchemaVersion
    case unsupportedSchemaVersion(Int)
}

private func decodeToolSchemaFixtureCorpus(_ data: Data) throws -> ToolSchemaFixtureCorpus {
    let corpus = try JSONDecoder().decode(ToolSchemaFixtureCorpus.self, from: data)
    guard let schemaVersion = corpus.schemaVersion else {
        throw ToolSchemaFixtureError.missingSchemaVersion
    }
    guard schemaVersion == 1 else {
        throw ToolSchemaFixtureError.unsupportedSchemaVersion(schemaVersion)
    }
    return corpus
}

private func toolSchemaFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/tool-schema/v1/normalization.json")
}

private func canonicalToolSchemaJSON(_ value: JSONValue) -> JSONValue {
    switch value {
    case .array(let values):
        return .array(values.map(canonicalToolSchemaJSON))
    case .object(let pairs):
        return .object(
            pairs
                .map { ($0.0, canonicalToolSchemaJSON($0.1)) }
                .sorted { $0.0 < $1.0 })
    default:
        return value
    }
}

@Test func sharedToolSchemaNormalizationCorpus() throws {
    let corpus = try decodeToolSchemaFixtureCorpus(
        Data(contentsOf: toolSchemaFixtureURL()))
    var names = Set<String>()

    for fixture in corpus.cases {
        #expect(!fixture.name.isEmpty)
        #expect(names.insert(fixture.name).inserted)
        #expect(fixture.mode == "normalize")

        let input = canonicalToolSchemaJSON(fixture.input)
        let expected = canonicalToolSchemaJSON(fixture.normalized)
        switch fixture.acceptance {
        case "rewritten":
            #expect(input != expected)
        case "preserved":
            #expect(input == expected)
        default:
            Issue.record(
                "unsupported fixture acceptance \(fixture.acceptance) in \(fixture.name)")
        }

        let encodedInput = try JSONEncoder().encode(fixture.input)
        let once = ToolSchemaNormalization.ensureParameterTypes(in: encodedInput)
        let actual = canonicalToolSchemaJSON(
            try JSONDecoder().decode(JSONValue.self, from: once))
        #expect(actual == expected, "normalization mismatch in \(fixture.name)")

        let twice = ToolSchemaNormalization.ensureParameterTypes(in: once)
        let idempotent = canonicalToolSchemaJSON(
            try JSONDecoder().decode(JSONValue.self, from: twice))
        #expect(idempotent == expected, "second pass changed \(fixture.name)")
    }
}

@Test func sharedToolSchemaNormalizationSchemaVersionFailsClosed() {
    for data in [
        Data(#"{"cases":[]}"#.utf8),
        Data(#"{"schema_version":2,"cases":[]}"#.utf8),
    ] {
        #expect(throws: ToolSchemaFixtureError.self) {
            _ = try decodeToolSchemaFixtureCorpus(data)
        }
    }
}

@Suite("Tool schema normalization (DAR-130)")
struct ToolSchemaNormalizationTests {
    private func parse(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }


    @Test func preservesExistingTypesAndNestedArrays() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "tags":{"type":"array","items":{"description":"a tag"}},
            "q":{"type":"string"}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        // Existing types untouched.
        #expect((props["q"] as? [String: Any])?["type"] as? String == "string")
        // Nested array `items` schema with no type gets defaulted.
        let items = try #require((props["tags"] as? [String: Any])?["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
    }

    @Test func nonToolBodyReturnedUnchanged() {
        let noTools = #"{"model":"m","messages":[]}"#.data(using: .utf8)!
        #expect(ToolSchemaNormalization.ensureParameterTypes(in: noTools) == noTools)
    }


    @Test func reservedMetadataDetectionIsSchemaAware() {
        let forged = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "value":{"type":"string","x-darkbloom-original-boolean-schema":true}
          }}}}]}
        """#.data(using: .utf8)!
        #expect(ToolSchemaNormalization.containsReservedMetadata(in: forged))

        let propertyNameOnly = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "x-darkbloom-original-boolean-schema":{"type":"string"}
          }}}}]}
        """#.data(using: .utf8)!
        #expect(!ToolSchemaNormalization.containsReservedMetadata(in: propertyNameOnly))
    }
}

extension ToolSchemaNormalizationTests {
    private func toolParams(_ data: Data) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let tools = root["tools"] as? [[String: Any]] ?? []
        let fn = tools.first?["function"] as? [String: Any] ?? [:]
        return fn["parameters"] as? [String: Any] ?? [:]
    }

    @Test func recursesIntoAdditionalProperties() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "meta":{"additionalProperties":{"description":"a value"}}}}}}]}
        """#.data(using: .utf8)!
        let props = try #require(toolParams(ToolSchemaNormalization.ensureParameterTypes(in: body))["properties"] as? [String: Any])
        let meta = try #require(props["meta"] as? [String: Any])
        // The map-shaped param node is typed "object"...
        #expect(meta["type"] as? String == "object")
        // ...and its inner additionalProperties schema gets a default type too.
        let addl = try #require(meta["additionalProperties"] as? [String: Any])
        #expect(addl["type"] as? String == "string")
    }

}

extension ToolSchemaNormalizationTests {
    @Test func skipsNormalizationForOversizedBodies() {
        // A body above the cap is returned unchanged BEFORE any parse, even though
        // it contains "tools" — bounding the JSON round-trip cost (DoS amplification).
        var body = Data(#"{"tools":["#.utf8)
        body.append(Data(count: ToolSchemaNormalization.maxNormalizationBytes))
        #expect(ToolSchemaNormalization.ensureParameterTypes(in: body) == body)
    }
    // MARK: - Array-typed (nullable) `type` values — the second DAR-130 class.
    // `"type": ["string","null"]` is what Pydantic emits for Optional[...] tool
    // parameters; the gemma template's `| upper` crashed on the list ("upper
    // filter requires string", reproduced on prod 2026-06-10).

    @Test func collapsesArrayTypeSkippingLeadingNull() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "n":{"type":["null","integer"]}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((props["n"] as? [String: Any])?["type"] as? String == "integer")
    }

    @Test func collapsesArrayTypeInNestedObjectAndItems() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"set_alarm",
          "parameters":{"type":"object","properties":{
            "opts":{"type":"object","properties":{"snooze":{"type":["integer","null"]}}},
            "tags":{"type":"array","items":{"type":["string","null"]}}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        let snooze = try #require(((props["opts"] as? [String: Any])?["properties"] as? [String: Any])?["snooze"] as? [String: Any])
        #expect(snooze["type"] as? String == "integer")
        let items = try #require((props["tags"] as? [String: Any])?["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
    }

    @Test func unionMemberWithArrayTypeStillDrivesParentInference() throws {
        // Ordering is load-bearing: members collapse BEFORE the parent's union
        // inference, so a first member declaring ["string","null"] must yield a
        // "string" parent type (not fall through to the default).
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "u":{"anyOf":[{"type":["string","null"]},{"type":"integer"}],"description":"u"}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((props["u"] as? [String: Any])?["type"] as? String == "string")
    }

    @Test func collapsesArrayTypeInsideAdditionalPropertiesSchema() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "kv":{"type":"object","additionalProperties":{"type":["number","null"]}}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        let addl = try #require((props["kv"] as? [String: Any])?["additionalProperties"] as? [String: Any])
        #expect(addl["type"] as? String == "number")
        #expect(addl["nullable"] as? Bool == true)
    }

    // Go: TestNormalizeToolSchemas_MultiConcreteTypeArrayWithExistingCombinatorCollapsesOnly
    @Test func multiConcreteTypeArrayWithExistingCombinatorCollapsesOnly() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "v":{"type":["string","integer"],"anyOf":[{"minLength":1}]},
            "w":{"type":["string","integer"],"allOf":[{"minLength":1}]}}}}}]}
        """#.data(using: .utf8)!

        let props = try #require(
            toolParams(ToolSchemaNormalization.ensureParameterTypes(in: body))["properties"]
                as? [String: Any])
        // The author's combinator keeps its written semantics: no second
        // union is layered on; the authored member survives (type-injected
        // only) and the type still collapses to the first concrete member.
        let v = try #require(props["v"] as? [String: Any])
        #expect(v["type"] as? String == "string")
        let variants = try #require(v["anyOf"] as? [[String: Any]])
        #expect(variants.count == 1)
        #expect(variants.first?["minLength"] as? Int == 1)
        let w = try #require(props["w"] as? [String: Any])
        #expect(w["anyOf"] == nil)
        #expect(w["type"] as? String == "string")
    }

}
