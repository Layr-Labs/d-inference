import Foundation
import Testing

@testable import ProviderCore

/// E1 crash-corpus mirror (2026-07-15 platform errors deep dive) of the
/// coordinator's `toolschema_corpus_test.go`: valid JSON-Schema shapes the
/// marker-key heuristic previously let through UNTYPED, crashing the served
/// Gemma template's `{{ value['type'] | upper }}` ("upper filter requires
/// string", 23k provider 500s/day). The positional rule guarantees a string
/// `type` on every value in a schema-positional slot.
@Suite("Tool schema normalization crash corpus (E1)")
struct ToolSchemaNormalizationCorpusTests {

    private func normalizedProps(_ parametersJSON: String) throws -> [String: Any] {
        let body = """
            {"tools":[{"type":"function","function":{"name":"f",
              "parameters":\(parametersJSON)}}]}
            """.data(using: .utf8)!
        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let root = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
        let tools = try #require(root["tools"] as? [[String: Any]])
        let function = try #require(tools[0]["function"] as? [String: Any])
        let params = try #require(function["parameters"] as? [String: Any])
        return try #require(params["properties"] as? [String: Any])
    }

    private func typeOf(_ node: Any?) -> String? {
        (node as? [String: Any])?["type"] as? String
    }

    @Test func emptyPropertySchemaGainsStringType() throws {
        let props = try normalizedProps(#"{"type":"object","properties":{"x":{}}}"#)
        #expect(typeOf(props["x"]) == "string")
    }

    @Test func markerlessAnnotationOnlyNodesGainStringType() throws {
        let cases: [String: String] = [
            "const-only": #"{"const":"fixed"}"#,
            "default-only": #"{"default":5}"#,
            "title-only": #"{"title":"T"}"#,
            "format-only": #"{"format":"date-time"}"#,
            "pattern-only": #"{"pattern":"^a"}"#,
            "ref-only": ##"{"$ref":"#/$defs/x"}"##,
            "minimum-only": #"{"minimum":1}"#,
            "maxLength-only": #"{"maxLength":10}"#,
        ]
        for (name, schema) in cases {
            let props = try normalizedProps(
                #"{"type":"object","properties":{"x":"# + schema + "}}")
            let node = try #require(props["x"] as? [String: Any], "\(name)")
            #expect(node["type"] as? String == "string", "\(name)")
            // The original annotation key survives beside the injected type.
            #expect(node.count == 2, "\(name): \(node)")
        }
    }

    @Test func booleanPropertySchemasBecomeStringTyped() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"x":true,"y":false}}"#)
        for name in ["x", "y"] {
            let node = try #require(props[name] as? [String: Any], "\(name)")
            #expect(node["type"] as? String == "string", "\(name)")
            #expect(node.count == 1, "\(name)")
        }
    }

    @Test func booleanItemsBecomeStringTyped() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"arr":{"type":"array","items":true}}}"#)
        let arr = try #require(props["arr"] as? [String: Any])
        let items = try #require(arr["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
    }

    @Test func scalarNonStringTypeCollapses() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"n":{"type":123},"o":{"type":42,"properties":{"inner":{}}}}}"#)
        #expect(typeOf(props["n"]) == "string")
        let o = try #require(props["o"] as? [String: Any])
        #expect(o["type"] as? String == "object")
        let inner = (o["properties"] as? [String: Any])?["inner"]
        #expect(typeOf(inner) == "string")
    }

    @Test func patternPropertiesValuesAreSchemas() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"env":{"type":"object","patternProperties":{"^ENV_":{},"^ANY_":true}}}}"#)
        let env = try #require(props["env"] as? [String: Any])
        let pp = try #require(env["patternProperties"] as? [String: Any])
        #expect(typeOf(pp["^ENV_"]) == "string")
        #expect(typeOf(pp["^ANY_"]) == "string")
    }

    @Test func patternPropertiesOnlyNodeInfersObject() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"env":{"patternProperties":{"^X_":{"type":"string"}}}}}"#)
        #expect(typeOf(props["env"]) == "object")
    }

    @Test func prefixItemsMembersAreSchemas() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"pair":{"prefixItems":[{},{"const":1},true]}}}"#)
        let pair = try #require(props["pair"] as? [String: Any])
        #expect(pair["type"] as? String == "array")
        let members = try #require(pair["prefixItems"] as? [Any])
        #expect(members.count == 3)
        for member in members {
            #expect(typeOf(member) == "string")
        }
    }

    @Test func tupleFormItemsMembersAreSchemas() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"tup":{"type":"array","items":[{},false]}}}"#)
        let tup = try #require(props["tup"] as? [String: Any])
        let members = try #require(tup["items"] as? [Any])
        for member in members {
            #expect(typeOf(member) == "string")
        }
    }

    @Test func markerlessUnionMembersAreSchemas() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"u":{"anyOf":[{},{"const":3}]},"o":{"oneOf":[{"format":"uuid"}]},"a":{"allOf":[{}]}}}"#)
        for (name, key) in [("u", "anyOf"), ("o", "oneOf"), ("a", "allOf")] {
            let node = try #require(props[name] as? [String: Any], "\(name)")
            let members = try #require(node[key] as? [Any], "\(name)")
            for member in members {
                #expect(typeOf(member) == "string", "\(name).\(key)")
            }
        }
    }

    @Test func emptyMapAdditionalPropertiesGainsType() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"meta":{"type":"object","additionalProperties":{}}}}"#)
        let meta = try #require(props["meta"] as? [String: Any])
        #expect(typeOf(meta["additionalProperties"]) == "string")
    }

    @Test func bareBooleanAdditionalPropertiesUntouched() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"open":{"type":"object","additionalProperties":true}}}"#)
        let open = try #require(props["open"] as? [String: Any])
        #expect(open["additionalProperties"] as? Bool == true)
        #expect(!(open["additionalProperties"] is [String: Any]))
    }

    /// Positional awareness must not leak to non-positional roots: a bare `{}`
    /// parameters and a marker-less junk-map root stay untyped.
    @Test func rootStaysMarkerGated() throws {
        let body = """
            {"tools":[
              {"type":"function","function":{"name":"noargs","parameters":{}}},
              {"type":"function","function":{"name":"junk","parameters":{"foo":"bar"}}}]}
            """.data(using: .utf8)!
        let out = ToolSchemaNormalization.ensureParameterTypes(in: body)
        let root = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
        let tools = try #require(root["tools"] as? [[String: Any]])
        let empty = try #require(
            (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(empty.isEmpty)
        let junk = try #require(
            (tools[1]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(junk["type"] == nil)
        #expect(junk["foo"] as? String == "bar")
    }

    /// A numeric 0/1 property value must NOT be mistaken for a boolean schema
    /// (JSONSerialization bridges both through NSNumber).
    @Test func numericZeroOneNotMistakenForBooleanSchema() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"one":1,"zero":0}}"#)
        // Scalars are not booleans: the shared normalizer leaves them for the
        // model-scoped enforcement (Gemma4ToolSchemaEnforcement) to repair.
        #expect(props["one"] as? Int == 1)
        #expect(props["zero"] as? Int == 0)
    }
}
