import Foundation
import Testing

@testable import ProviderCore

/// E1 last-line-of-defense invariants for gemma4 tool specs
/// (`Gemma4TemplateFix.normalizeTools` → `Gemma4ToolSchemaEnforcement`): even
/// if a caller bypasses the shared normalizers, every `function.parameters`
/// handed to the served Gemma template is a mapping in which EVERY property
/// value is a mapping with a String `type`, the non-empty root carries a
/// String `type` (the macro's closing brace lives in that branch), OBJECT
/// nodes carry a mapping `properties` (so the template's filter_keys fallback
/// never iterates junk keys), and `required` members are strings.
@Suite("Gemma4 tool schema enforcement (E1)")
struct Gemma4ToolSchemaEnforcementTests {

    private let gemmaContext = ChatTemplateFixContext(
        modelId: "gemma-4-26b-a4b-it-qat-4bit", modelType: "gemma4_text")

    private func tool(parameters: (any Sendable)?) -> [String: any Sendable] {
        var function: [String: any Sendable] = [
            "name": "f", "description": "d",
        ]
        if let parameters {
            function["parameters"] = parameters
        }
        return ["type": "function", "function": function]
    }

    private func params(of tool: [String: any Sendable]?) -> [String: any Sendable]? {
        (tool?["function"] as? [String: any Sendable])?["parameters"]
            as? [String: any Sendable]
    }

    @Test func appliesGatesOnGemma4() {
        #expect(Gemma4TemplateFix.applies(to: gemmaContext))
        #expect(
            !Gemma4TemplateFix.applies(
                to: ChatTemplateFixContext(modelId: "gpt-oss-20b", modelType: "gpt_oss")))
    }

    @Test func scalarAndBooleanPropertyValuesBecomeTypedMappings() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [
                "type": "object",
                "properties": [
                    "num": 5,
                    "str": "shorthand",
                    "flag": true,
                ] as [String: any Sendable],
            ] as [String: any Sendable])
        ])
        let props = try #require(params(of: out.first)?["properties"] as? [String: any Sendable])
        for name in ["num", "str", "flag"] {
            let node = try #require(props[name] as? [String: any Sendable], "\(name)")
            #expect(node["type"] as? String == "string", "\(name)")
        }
    }

    @Test func typelessPropertyMappingsGainStringType() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [
                "properties": [
                    "empty": [String: any Sendable](),
                    "constOnly": ["const": "x"] as [String: any Sendable],
                ] as [String: any Sendable]
            ] as [String: any Sendable])
        ])
        let root = try #require(params(of: out.first))
        // Root gains a String type (parameters:{ only closes in that branch).
        #expect(root["type"] as? String == "object")
        let props = try #require(root["properties"] as? [String: any Sendable])
        for name in ["empty", "constOnly"] {
            let node = try #require(props[name] as? [String: any Sendable], "\(name)")
            #expect(node["type"] as? String == "string", "\(name)")
        }
    }

    @Test func nonMappingParametersAreDropped() throws {
        for junk in ["a string" as any Sendable, [1, 2] as [any Sendable], 42 as any Sendable] {
            let out = Gemma4TemplateFix.normalizeTools([tool(parameters: junk)])
            let function = try #require(out.first?["function"] as? [String: any Sendable])
            #expect(function["parameters"] == nil)
        }
    }

    @Test func emptyParametersAreDropped() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [String: any Sendable]())
        ])
        let function = try #require(out.first?["function"] as? [String: any Sendable])
        #expect(function["parameters"] == nil)
    }

    @Test func objectNodeWithoutPropertiesGainsEmptyProperties() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [
                "type": "object",
                "properties": [
                    // OBJECT-typed with junk keys and NO properties: without the
                    // injected empty `properties` the template's filter_keys
                    // fallback iterates `minProperties`/`patternProperties` as
                    // if they were property schemas.
                    "cfg": [
                        "type": "object",
                        "minProperties": 1,
                        "patternProperties": ["^e_": [String: any Sendable]()]
                            as [String: any Sendable],
                    ] as [String: any Sendable]
                ] as [String: any Sendable],
            ] as [String: any Sendable])
        ])
        let props = try #require(params(of: out.first)?["properties"] as? [String: any Sendable])
        let cfg = try #require(props["cfg"] as? [String: any Sendable])
        let injected = try #require(cfg["properties"] as? [String: any Sendable])
        #expect(injected.isEmpty)
    }

    @Test func requiredMembersAreCoercedToStrings() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [
                "type": "object",
                "properties": ["a": ["type": "string"] as [String: any Sendable]]
                    as [String: any Sendable],
                "required": ["a", 1, true, ["nested": "junk"] as [String: any Sendable]]
                    as [any Sendable],
            ] as [String: any Sendable])
        ])
        let required = try #require(params(of: out.first)?["required"] as? [String])
        #expect(required.count == 3)
        #expect(required[0] == "a")
        // Scalars stringified, the composite dropped.
        #expect(required.allSatisfy { !$0.isEmpty })
    }

    @Test func nonArrayRequiredIsRemoved() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [
                "type": "object",
                "properties": [String: any Sendable](),
                "required": "a",
            ] as [String: any Sendable])
        ])
        let root = try #require(params(of: out.first))
        #expect(root["required"] == nil)
    }

    @Test func nestedItemsAreEnforced() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            tool(parameters: [
                "type": "object",
                "properties": [
                    "arr": [
                        "type": "array",
                        "items": [
                            "properties": ["inner": 7] as [String: any Sendable],
                            "required": [3] as [any Sendable],
                        ] as [String: any Sendable],
                    ] as [String: any Sendable]
                ] as [String: any Sendable],
            ] as [String: any Sendable])
        ])
        let props = try #require(params(of: out.first)?["properties"] as? [String: any Sendable])
        let arr = try #require(props["arr"] as? [String: any Sendable])
        let items = try #require(arr["items"] as? [String: any Sendable])
        let inner = try #require(
            (items["properties"] as? [String: any Sendable])?["inner"] as? [String: any Sendable])
        #expect(inner["type"] as? String == "string")
        #expect(items["required"] as? [String] == ["3"])
    }

    @Test func functionNameAndDescriptionCoercedToStrings() throws {
        let out = Gemma4TemplateFix.normalizeTools([
            [
                "type": "function",
                "function": ["name": 7, "parameters": ["properties": [String: any Sendable]()] as [String: any Sendable]]
                    as [String: any Sendable],
            ]
        ])
        let function = try #require(out.first?["function"] as? [String: any Sendable])
        // The declaration macro string-concatenates the name and renders the
        // description unconditionally — both must exist as strings.
        #expect(function["name"] as? String == "7")
        #expect(function["description"] as? String == "")
    }

    @Test func wellFormedSpecPassesThroughValueEquivalent() throws {
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "city": ["type": "string", "description": "c"] as [String: any Sendable],
                "opts": [
                    "type": "object",
                    "properties": ["verbose": ["type": "boolean"] as [String: any Sendable]]
                        as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["city"],
        ]
        let out = Gemma4TemplateFix.normalizeTools([tool(parameters: parameters)])
        let root = try #require(params(of: out.first))
        #expect(root["type"] as? String == "object")
        let props = try #require(root["properties"] as? [String: any Sendable])
        let city = try #require(props["city"] as? [String: any Sendable])
        #expect(city["type"] as? String == "string")
        #expect(city["description"] as? String == "c")
        let opts = try #require(props["opts"] as? [String: any Sendable])
        #expect((opts["properties"] as? [String: any Sendable])?.count == 1)
        #expect(root["required"] as? [String] == ["city"])
    }
}
