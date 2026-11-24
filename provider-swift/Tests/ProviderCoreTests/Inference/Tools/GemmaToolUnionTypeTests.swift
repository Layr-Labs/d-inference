import Foundation
import Jinja
import MLXLMServer
import Testing

@testable import ProviderCore

/// A Gemma tool parameter whose union of `string` and one other scalar type
/// used to render as STRING renders as that other type, so the model writes a
/// typed value instead of quoting it; the union stays on the wire. Such a
/// coordinator request is served without the prompt cache.
@Suite("Gemma tool union render type")
struct GemmaToolUnionTypeTests {
    /// The request as the serving entry point decodes it (the shared repair
    /// runs here), with `schema` as the one parameter `value` of tool `f`.
    private static func request(_ schema: [String: Any]) throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: [
            "model": "gemma-4-26b-qat-4bit",
            "messages": [["role": "user", "content": "Go."]],
            "tools": [["type": "function", "function": [
                "name": "f", "description": "d",
                "parameters": ["type": "object", "properties": ["value": schema], "required": ["value"]],
            ]]],
        ] as [String: Any]))
    }

    /// The render type of every property, as the served template prints it
    /// (`value['type'] | upper`), over the tools `normalizeTools` gives the
    /// template.
    private static func renderTypes(_ request: OpenAIChatCompletionRequest, modelType: String) throws -> String {
        let tools = ChatTemplateFixes.normalizeTools(
            request.tools?.map { $0.toolSpec() }, context: .init(modelType: modelType))
        let template = try Template(
            "{%- for tool in tools -%}{%- for k, v in tool.function.parameters.properties | dictsort -%}"
                + "{{ k }}={{ v['type'] | upper }}{%- if v['nullable'] -%}?{%- endif -%};"
                + "{%- if v['properties'] is defined -%}{%- for k2, v2 in v['properties'] | dictsort -%}"
                + "{{ k }}.{{ k2 }}={{ v2['type'] | upper }};{%- endfor -%}{%- endif -%}"
                + "{%- endfor -%}{%- endfor -%}",
            with: .init(lstripBlocks: true, trimBlocks: true))
        return try template.render(["tools": try Jinja.Value(any: tools ?? [])])
    }

    private static let stringFirstUnions: [([String: Any], String)] = [
        (["type": ["string", "integer"]], "INTEGER"),
        (["anyOf": [["type": "string"], ["type": "integer"]]], "INTEGER"),
        (["oneOf": [["type": "string"], ["type": "integer"]]], "INTEGER"),
        (["type": ["string", "number"]], "NUMBER"),
        (["anyOf": [["type": "string"], ["type": "number"]]], "NUMBER"),
        (["oneOf": [["type": "string"], ["type": "number"]]], "NUMBER"),
        (["type": ["string", "boolean"]], "BOOLEAN"),
        (["anyOf": [["type": "string"], ["type": "boolean"]]], "BOOLEAN"),
        (["oneOf": [["type": "string"], ["type": "boolean"]]], "BOOLEAN"),
    ]

    @Test("a string-first union of string and one scalar renders as that scalar for Gemma")
    func stringFirstUnionRendersItsTypedMember() throws {
        for (schema, expected) in Self.stringFirstUnions {
            let request = try Self.request(schema)
            #expect(try Self.renderTypes(request, modelType: "gemma4") == "value=\(expected);", "\(schema)")
            // The union stays on the wire for validation.
            let wire = try #require(request.tools?.first?.toolSpec())
            let parameters = (wire["function"] as? [String: any Sendable])?["parameters"] as? [String: any Sendable]
            let value = (parameters?["properties"] as? [String: any Sendable])?["value"] as? [String: any Sendable]
            #expect(value?["anyOf"] != nil || value?["oneOf"] != nil, "\(schema)")
        }
    }

    @Test("a null member is skipped and stays nullable; nested properties are covered")
    func nullMemberAndNestedProperty() throws {
        #expect(try Self.renderTypes(Self.request(["type": ["string", "integer", "null"]]), modelType: "gemma4")
            == "value=INTEGER?;")
        let nested = try Self.request(["type": "object", "properties": ["cents": ["type": ["string", "integer"]]]])
        #expect(try Self.renderTypes(nested, modelType: "gemma4") == "value=OBJECT;value.cents=INTEGER;")
    }

    @Test("other unions, enums and plain types keep their render type")
    func otherShapesKeepTheirType() throws {
        let unchanged: [([String: Any], String)] = [
            (["enum": ["default", "inherit", "archive", -1]], "STRING"),
            (["type": ["integer", "string"]], "INTEGER"),
            (["anyOf": [["type": "number"], ["type": "string"]]], "NUMBER"),
            (["type": ["string", "integer", "boolean"]], "STRING"),
            (["type": ["string", "object"]], "STRING"),
            (["type": "string"], "STRING"),
            (["type": "integer"], "INTEGER"),
            (["type": ["string", "null"]], "STRING?"),
        ]
        for (schema, expected) in unchanged {
            #expect(try Self.renderTypes(Self.request(schema), modelType: "gemma4") == "value=\(expected);", "\(schema)")
            #expect(!GemmaToolUnionTypeCache.changesRender(try Self.request(schema), modelType: "gemma4"), "\(schema)")
        }
    }

    @Test("other families keep the shared repair's render type",
          arguments: ["qwen3_5", "qwen3_5_moe", "qwen4_exp", "nemotron_h", "gpt_oss", "llama"])
    func otherFamiliesUnchanged(modelType: String) throws {
        let request = try Self.request(["type": ["string", "integer"]])
        #expect(!GemmaToolUnionTypeCache.changesRender(request, modelType: modelType))
        let tools = ChatTemplateFixes.normalizeTools(
            request.tools?.map { $0.toolSpec() }, context: .init(modelType: modelType))
        let parameters = (tools?.first?["function"] as? [String: any Sendable])?["parameters"] as? [String: any Sendable]
        let value = (parameters?["properties"] as? [String: any Sendable])?["value"] as? [String: any Sendable]
        #expect(value?["type"] as? String == "string")
    }

    // MARK: - Served cold

    private static let planned = RemotePrefixCacheContext(cacheScope: "scope-a", cacheReceiptNonce: "nonce-a")

    @Test("a planned Gemma request whose tool render changed is served without the prompt cache",
          arguments: ["gemma4", "gemma4_text"])
    func changedRenderServesCold(modelType: String) throws {
        let served = GemmaToolUnionTypeCache.servingContext(
            Self.planned, for: try Self.request(["type": ["string", "integer"]]), modelType: modelType)
        #expect(served.servedCold)
        #expect(served.context.receiptNonce == nil && served.context.scope == nil && !served.context.cacheEnabled)
    }

    @Test("an unchanged render, an unplanned request or one already served cold keeps its context")
    func otherRequestsKeepTheirContext() throws {
        let unchanged = GemmaToolUnionTypeCache.servingContext(
            Self.planned, for: try Self.request(["type": ["integer", "string"]]), modelType: "gemma4")
        #expect(!unchanged.servedCold && unchanged.context == Self.planned)
        let cold = RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil)
        let unplanned = GemmaToolUnionTypeCache.servingContext(
            cold, for: try Self.request(["type": ["string", "integer"]]), modelType: "gemma4")
        #expect(!unplanned.servedCold && unplanned.context == cold)
        let otherFamily = GemmaToolUnionTypeCache.servingContext(
            Self.planned, for: try Self.request(["type": ["string", "integer"]]), modelType: "qwen3_5")
        #expect(!otherFamily.servedCold && otherFamily.context == Self.planned)
    }
}
