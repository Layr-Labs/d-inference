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
