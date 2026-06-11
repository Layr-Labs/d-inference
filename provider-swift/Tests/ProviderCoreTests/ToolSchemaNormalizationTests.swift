import Foundation
import Testing

@testable import ProviderCore

@Suite("Tool schema normalization (DAR-130)")
struct ToolSchemaNormalizationTests {
    private func parse(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test func injectsTypeIntoTypelessParameterPropertyAndObject() throws {
        // A legitimate OpenAI schema: the `unit` property has enum+description but
        // no explicit `type`, and the parameters object itself omits `type`.
        let body = #"""
        {"model":"gemma-4-26b","messages":[{"role":"user","content":"hi"}],
         "tools":[{"type":"function","function":{"name":"get_weather",
           "parameters":{"properties":{"unit":{"enum":["c","f"],"description":"unit"}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let root = parse(out)
        let tools = try #require(root["tools"] as? [[String: Any]])
        let function = try #require(tools[0]["function"] as? [String: Any])
        let params = try #require(function["parameters"] as? [String: Any])

        #expect(params["type"] as? String == "object")
        let props = try #require(params["properties"] as? [String: Any])
        let unit = try #require(props["unit"] as? [String: Any])
        // Defaulted to "string" so `{{ value['type'] | upper }}` no longer throws.
        #expect(unit["type"] as? String == "string")
        // The original enum/description are preserved.
        #expect((unit["enum"] as? [Any])?.count == 2)
        #expect(unit["description"] as? String == "unit")
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

    @Test func derivesUnionTypeInsteadOfBlanketString() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "n":{"anyOf":[{"type":"number"},{"type":"null"}]}}}}}]}
        """#.data(using: .utf8)!
        let props = try #require(toolParams(ToolSchemaNormalization.ensureParameterTypes(in: body))["properties"] as? [String: Any])
        let n = try #require(props["n"] as? [String: Any])
        // A nullable-number union borrows "number", not a mislabelling "string".
        #expect(n["type"] as? String == "number")
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

    @Test func collapsesNullableArrayTypeToConcreteMember() throws {
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"get_weather",
          "parameters":{"type":"object","properties":{
            "city":{"type":["string","null"],"description":"city"}},
            "required":["city"]}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        let city = try #require(props["city"] as? [String: Any])
        #expect(city["type"] as? String == "string")
        // Nullability preserved losslessly via the template-supported key.
        #expect(city["nullable"] as? Bool == true)
    }

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

    @Test func collapsesNullOnlyArrayTypeToNullString() throws {
        // ["null"] has no concrete member — keep the honest "null", which still
        // renders (it is a string for `| upper`).
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "x":{"type":["null"]}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((props["x"] as? [String: Any])?["type"] as? String == "null")
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

    @Test func malformedNonStringTypeFallsBackToStructuralInference() throws {
        // A numeric `type` is invalid JSON Schema; repair it from structure
        // (properties present → object) instead of leaving the list/number for
        // the template to choke on.
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":"object","properties":{
            "cfg":{"type":42,"properties":{"k":{"type":"string"}}},
            "v":{"type":7,"description":"v"}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let props = try #require((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        #expect((props["cfg"] as? [String: Any])?["type"] as? String == "object")
        #expect((props["v"] as? [String: Any])?["type"] as? String == "string")
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

    @Test func collapsesArrayTypeOnTopLevelParametersNode() throws {
        // The template also renders params['type'] | upper at the top level.
        let body = #"""
        {"tools":[{"type":"function","function":{"name":"f",
          "parameters":{"type":["object","null"],"properties":{"q":{"type":"string"}}}}}]}
        """#.data(using: .utf8)!

        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let function = try #require((parse(out)["tools"] as? [[String: Any]])?[0]["function"] as? [String: Any])
        let params = try #require(function["parameters"] as? [String: Any])
        #expect(params["type"] as? String == "object")
        #expect(params["nullable"] as? Bool == true)
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
}
