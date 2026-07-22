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

    /// A bare `{}` property is the "anything" schema — semantically the
    /// boolean `true` schema — so it gets the same render-safe rewrite with
    /// the marker, letting auto validation restore allow-all semantics.
    @Test func emptyPropertySchemaGainsStringType() throws {
        let props = try normalizedProps(#"{"type":"object","properties":{"x":{}}}"#)
        let x = try #require(props["x"] as? [String: Any])
        #expect(x["type"] as? String == "string")
        #expect(
            x[ToolSchemaNormalization.originalBooleanSchemaKey] as? Bool == true)
        #expect(x.count == 2)
    }

    @Test func markerlessAnnotationOnlyNodesGainStringType() throws {
        let cases: [String: String] = [
            "const-only": #"{"const":"fixed"}"#,
            "default-only": #"{"default":5}"#,
            "title-only": #"{"title":"T"}"#,
            "format-only": #"{"format":"date-time"}"#,
            "pattern-only": #"{"pattern":"^a"}"#,
            "ref-only": ##"{"$ref":"#/$defs/x"}"##,
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
        for (name, expected) in ["x": true, "y": false] {
            let node = try #require(props[name] as? [String: Any], "\(name)")
            #expect(node["type"] as? String == "string", "\(name)")
            #expect(
                node[ToolSchemaNormalization.originalBooleanSchemaKey] as? Bool
                    == expected,
                "\(name)")
            #expect(node.count == 2, "\(name)")
        }
    }

    @Test func booleanItemsBecomeStringTyped() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"arr":{"type":"array","items":true}}}"#)
        let arr = try #require(props["arr"] as? [String: Any])
        let items = try #require(arr["items"] as? [String: Any])
        #expect(items["type"] as? String == "string")
        #expect(
            items[ToolSchemaNormalization.originalBooleanSchemaKey] as? Bool
                == true)
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
        // `{}` and boolean members default to string; a const member keeps
        // its value's type ("number" for const 1) so validation stays
        // satisfiable.
        for (index, want) in ["string", "number", "string"].enumerated() {
            #expect(typeOf(members[index]) == want, "prefixItems[\(index)]")
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
        // Marker-less members default to string; the const member keeps its
        // value's type ("number" for const 3) so validation stays satisfiable.
        for (name, key, types) in [
            ("u", "anyOf", ["string", "number"]),
            ("o", "oneOf", ["string"]),
            ("a", "allOf", ["string"]),
        ] {
            let node = try #require(props[name] as? [String: Any], "\(name)")
            let members = try #require(node[key] as? [Any], "\(name)")
            #expect(members.count == types.count, "\(name).\(key)")
            for (index, want) in types.enumerated() {
                #expect(typeOf(members[index]) == want, "\(name).\(key)[\(index)]")
            }
        }
    }

    /// A typeless node with const/enum keeps its original value semantics:
    /// the injected render type comes from the finite values, not the string
    /// default (which made every schema-valid non-string emission fail
    /// post-generation validation), and a null member beside a concrete one
    /// is preserved as nullable. Mirror of the coordinator corpus test.
    @Test func typelessFiniteValuesKeepOriginalSemantics() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"count":{"const":1},"level":{"enum":[1,2,null]},"flag":{"const":true},"tag":{"enum":["a","b"]},"none":{"const":null}}}"#)
        for (name, want) in [
            ("count", "number"),
            ("level", "number"),
            ("flag", "boolean"),
            ("tag", "string"),
            ("none", "null"),
        ] {
            #expect(typeOf(props[name]) == want, "\(name)")
        }
        let level = try #require(props["level"] as? [String: Any])
        #expect(level["nullable"] as? Bool == true)
        let count = try #require(props["count"] as? [String: Any])
        #expect(count["nullable"] == nil)
    }

    /// A typeless node whose only content is type-scoped assertions keeps the
    /// family those assertions constrain: `{"minimum":5}` accepts 6, so the
    /// injected render type must be "number", not the string default. Mirror
    /// of the coordinator corpus test.
    @Test func typelessAssertionFamiliesKeepOriginalSemantics() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"score":{"minimum":5,"maximum":10},"steps":{"multipleOf":2},"list":{"minItems":1,"uniqueItems":true},"shape":{"required":["a"]},"code":{"pattern":"^ab$"}}}"#)
        for (name, want) in [
            ("score", "number"),
            ("steps", "number"),
            ("list", "array"),
            ("shape", "object"),
            ("code", "string"),
        ] {
            #expect(typeOf(props[name]) == want, "\(name)")
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

    /// Post-push Codex P2: an OBJECT-typed node without a mapping
    /// `properties` re-exposes the served template's `filter_keys=true`
    /// fallback, which iterates the node's OWN keys (patternProperties has
    /// no `type` -> `| upper` throws). The shared normalizer must inject an
    /// empty `properties` map — mirror of coordinator toolschema.go and
    /// gemma4 enforcement invariant 4.
    @Test func objectNodesAlwaysCarryPropertiesMap() throws {
        let props = try normalizedProps(
            #"{"type":"object","properties":{"env":{"type":"object","patternProperties":{"^ENV_":{"type":"string"}}}}}"#)
        let env = try #require(props["env"] as? [String: Any])
        let injected = try #require(env["properties"] as? [String: Any], "object node must gain properties")
        #expect(injected.isEmpty)

        // Typeless patternProperties-only node: inferred object gains it too.
        let props2 = try normalizedProps(
            #"{"type":"object","properties":{"env":{"patternProperties":{"^X_":{"type":"string"}}}}}"#)
        let env2 = try #require(props2["env"] as? [String: Any])
        #expect(env2["type"] as? String == "object")
        #expect(env2["properties"] is [String: Any])

        // Non-mapping properties on an object node becomes an empty map.
        let props3 = try normalizedProps(
            #"{"type":"object","properties":{"o":{"type":"object","properties":"junk"}}}"#)
        let o = try #require(props3["o"] as? [String: Any])
        #expect(o["properties"] is [String: Any])
    }
}
