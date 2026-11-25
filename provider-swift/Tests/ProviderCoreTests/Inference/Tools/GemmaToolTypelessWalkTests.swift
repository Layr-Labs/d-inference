import Foundation
import Jinja
import MLXLMServer
import Testing

@testable import ProviderCore

/// Invariant 8 beyond a bare `{}` property: a property that accepts any value
/// behind a local `$ref`, as an `anyOf`/`oneOf`/`allOf` of such members, or
/// as a typeless enum of mixed JSON types renders an empty type for Gemma, and
/// a tuple renders no STRING `items`, as the served template renders the
/// caller's own schema. Each needs the declarations as sent; such a
/// coordinator request is served without the prompt cache.
@Suite("Gemma typeless render positions")
struct GemmaToolTypelessWalkTests {
    /// A request whose tool `f` declares `value` as `schema`, with `root`
    /// merged into the parameters schema (for `$defs` / `definitions`).
    private static func body(_ schema: [String: Any], root: [String: Any] = [:]) throws -> Data {
        var parameters: [String: Any] = ["type": "object", "properties": ["value": schema], "required": ["value"]]
        parameters.merge(root) { _, new in new }
        return try JSONSerialization.data(withJSONObject: [
            "model": "gemma-4-26b-qat-4bit",
            "messages": [["role": "user", "content": "Go."]],
            "tools": [["type": "function", "function": ["name": "f", "description": "d", "parameters": parameters]]],
        ] as [String: Any])
    }

    /// The template input for `value` (render type, nullable, items present)
    /// and whether the served-cold rule fires, with and without the
    /// declarations as sent.
    private struct Render: Equatable {
        let type: String
        let nullable: Bool
        let hasItems: Bool
        let servedCold: Bool
    }

    private static func render(
        _ schema: [String: Any], root: [String: Any] = [:], withDeclarations: Bool = true
    ) throws -> Render {
        let data = try body(schema, root: root)
        let request = try ProviderLoop.decodeOpenAIRequest(data)
        let declared = withDeclarations ? ProviderLoop.extractChatTemplateControls(from: data).declaredTools : nil
        let tools = ChatTemplateFixes.normalizeTools(
            request.tools?.map { $0.toolSpec() }, context: .init(modelType: "gemma4"), declared: declared)
        let parameters = (tools?.first?["function"] as? [String: any Sendable])?["parameters"] as? [String: any Sendable]
        let value = try #require((parameters?["properties"] as? [String: any Sendable])?["value"] as? [String: any Sendable])
        return Render(
            type: value["type"] as? String ?? "<none>",
            nullable: value["nullable"] as? Bool == true,
            hasItems: value["items"] != nil,
            servedCold: GemmaToolUnionTypeCache.changesRender(request, modelType: "gemma4", declared: declared))
    }

    @Test("a local $ref to a schema without a type renders an empty type")
    func referenceToTypelessSchema() throws {
        for container in ["$defs", "definitions"] {
            let root: [String: Any] = [container: ["Cents": ["description": "Signed cents"]]]
            let schema: [String: Any] = ["$ref": "#/\(container)/Cents"]
            let rendered = try Self.render(schema, root: root)
            #expect(rendered == Render(type: "", nullable: false, hasItems: false, servedCold: true),
                    "\(container): \(rendered)")
            #expect(try Self.render(schema, root: root, withDeclarations: false).type == "string", "\(container)")
        }
        // A reference to a typed schema keeps its type.
        let typed: [String: Any] = ["$defs": ["Cents": ["type": "integer"]]]
        let kept = try Self.render(["$ref": "#/$defs/Cents"], root: typed)
        #expect(kept.type != "" && !kept.servedCold, "\(kept)")
    }

    /// The shared repair folds an `anyOf` with an any-value member (null or
    /// not, typed members or not) to `string` and keeps no `nullable`, as such
    /// an `anyOf` accepts every value; a `oneOf` of an any-value member and
    /// null keeps its members and gains `nullable`.
    @Test("an anyOf with an any-value member, or a oneOf of one and null, renders an empty type")
    func nullableAnyValue() throws {
        let cases: [([String: Any], Bool)] = [
            (["anyOf": [[:] as [String: Any], ["type": "null"]], "description": "Content or null"], false),
            (["anyOf": [["type": "null"], [:] as [String: Any]]], false),
            (["anyOf": [["type": "integer"], [:] as [String: Any]]], false),
            (["oneOf": [[:] as [String: Any], ["type": "null"]]], true),
        ]
        for (schema, nullable) in cases {
            let rendered = try Self.render(schema)
            #expect(rendered == Render(type: "", nullable: nullable, hasItems: false, servedCold: true),
                    "\(schema): \(rendered)")
            let repaired = try Self.render(schema, withDeclarations: false)
            #expect(repaired.type == "string" && !repaired.servedCold, "\(schema): \(repaired)")
        }
        // Without an any-value member the union keeps its render type.
        let typed = try Self.render(["anyOf": [["type": "integer"], ["type": "null"]]])
        #expect(typed == Render(type: "integer", nullable: true, hasItems: false, servedCold: false), "\(typed)")
    }

    @Test("an allOf of any-value members renders an empty type")
    func allOfAnyValue() throws {
        let schema: [String: Any] = ["description": "Note text", "allOf": [[:] as [String: Any]]]
        let rendered = try Self.render(schema)
        #expect(rendered == Render(type: "", nullable: false, hasItems: false, servedCold: true), "\(rendered)")
        #expect(try Self.render(schema, withDeclarations: false).type == "string")
    }

    @Test("a typeless enum of mixed JSON types renders an empty type; a single-type enum keeps STRING")
    func mixedEnum() throws {
        let mixed: [String: Any] = ["enum": ["default", "inherit", "archive", -1]]
        let rendered = try Self.render(mixed)
        #expect(rendered == Render(type: "", nullable: false, hasItems: false, servedCold: true), "\(rendered)")
        #expect(try Self.render(mixed, withDeclarations: false).type == "string")
        let strings = try Self.render(["enum": ["a", "b"]])
        #expect(strings.type == "string" && !strings.servedCold, "\(strings)")
    }

    @Test("a tuple renders no items block; an array with item schemas keeps its items")
    func tupleItems() throws {
        let tuple: [String: Any] = [
            "type": "array", "items": false,
            "prefixItems": [["type": "string"], ["type": "integer"], ["type": "boolean"]],
        ]
        let rendered = try Self.render(tuple)
        #expect(rendered == Render(type: "array", nullable: false, hasItems: false, servedCold: true), "\(rendered)")
        #expect(try Self.render(tuple, withDeclarations: false).hasItems)
        let list = try Self.render(["type": "array", "items": ["type": "integer"]])
        #expect(list.hasItems && !list.servedCold, "\(list)")
    }
}
