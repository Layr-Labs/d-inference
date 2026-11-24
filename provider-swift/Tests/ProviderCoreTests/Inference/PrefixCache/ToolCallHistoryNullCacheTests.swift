import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// An earlier tool call's null arguments reach the model as `null` on every
/// served family, and a coordinator request whose prompt that changes is
/// served without the prompt cache (`ToolCallHistoryNullCache`).
@Suite("Tool-call history nulls")
struct ToolCallHistoryNullCacheTests {
    private static let nullArguments =
        #"{"deadline":null,"flags":{"dark-mode":null},"rows":[[false,"Total"],null],"payload":{"data":[null,{}]},"owner":"ops"}"#

    private static func body(arguments: String, model: String = "served-model") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": "Use the tools."],
                ["role": "user", "content": "Update the record."],
                ["role": "assistant", "content": "", "tool_calls": [[
                    "id": "call_0", "type": "function",
                    "function": ["name": "update_record", "arguments": arguments],
                ]]],
                ["role": "tool", "tool_call_id": "call_0", "content": "done"],
                ["role": "user", "content": "Do it again."],
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "update_record", "description": "Update a record",
                    "parameters": ["type": "object", "properties": ["deadline": ["type": ["string", "null"]]]],
                ],
            ]],
        ] as [String: Any])
    }

    private static func request(arguments: String) throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(body(arguments: arguments))
    }

    private static let planned = RemotePrefixCacheContext(
        cacheScope: "scope-a", cacheReceiptNonce: "nonce-a", repeatedPrefixTokens: 4096)

    // MARK: - Served cold

    @Test("a planned request whose call history carries a null is served without the prompt cache",
          arguments: ["gemma4", "qwen3_5", "qwen3_5_moe", "qwen4_exp", "nemotron_h", "gpt_oss",
                      Inkling2ModelIdentity.modelType, "llama", nil] as [String?])
    func historyNullServesCold(modelType: String?) throws {
        let served = ToolCallHistoryNullCache.servingContext(
            Self.planned, for: try Self.request(arguments: Self.nullArguments),
            modelType: modelType, managedSuper: false)
        #expect(served.servedCold)
        #expect(served.context.receiptNonce == nil)
        #expect(served.context.scope == nil)
        #expect(!served.context.cacheEnabled)
        #expect(served.context.donationDemand == nil)
    }

    @Test("a request without a history null keeps its planned cache context")
    func noHistoryNullKeepsThePlan() throws {
        for arguments in [#"{"deadline":"2026-12-01","owner":"ops"}"#, "{}", #"{"note":"null"}"#] {
            let served = ToolCallHistoryNullCache.servingContext(
                Self.planned, for: try Self.request(arguments: arguments), modelType: "gemma4", managedSuper: false)
            #expect(!served.servedCold)
            #expect(served.context == Self.planned)
        }
    }

    @Test("a null only in a tool schema or message field keeps the plan")
    func schemaOrMessageNullKeepsThePlan() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "served-model",
            "messages": [
                ["role": "user", "content": "Hi.", "name": NSNull()],
                ["role": "assistant", "content": NSNull(), "tool_calls": [[
                    "id": "call_0", "type": "function", "function": ["name": "f", "arguments": #"{"a":1}"#],
                ]]],
                ["role": "tool", "tool_call_id": "call_0", "content": "ok"],
                ["role": "user", "content": "Again."],
            ],
            "tools": [["type": "function", "function": ["name": "f", "parameters": [
                "type": "object", "properties": ["a": ["type": "integer", "default": NSNull()]],
            ]]]],
        ] as [String: Any])
        let served = ToolCallHistoryNullCache.servingContext(
            Self.planned, for: try ProviderLoop.decodeOpenAIRequest(body), modelType: "qwen3_5", managedSuper: false)
        #expect(!served.servedCold)
        #expect(served.context == Self.planned)
    }

    @Test("an unplanned request is not counted as served cold")
    func unplannedRequestIsNotCounted() throws {
        let unplanned = RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil)
        let served = ToolCallHistoryNullCache.servingContext(
            unplanned, for: try Self.request(arguments: Self.nullArguments), modelType: "gemma4", managedSuper: false)
        #expect(!served.servedCold)
        #expect(served.context == unplanned)
    }

    /// GLM-5.3, MiMo, Flint and the managed Nemotron Super owner build their
    /// own history and already rendered these nulls; their prompts are
    /// unchanged, so they keep the plan.
    @Test("families whose history rendering did not change keep the plan",
          arguments: [("glm5_next", false), ("glm5_next_mtp", false), ("mimo_v2", false), ("flint", false),
                      ("nemotron_h", true)] as [(String, Bool)])
    func unchangedFamiliesKeepThePlan(modelType: String, managedSuper: Bool) throws {
        let served = ToolCallHistoryNullCache.servingContext(
            Self.planned, for: try Self.request(arguments: Self.nullArguments),
            modelType: modelType, managedSuper: managedSuper)
        #expect(!served.servedCold)
        #expect(served.context == Self.planned)
    }

    // MARK: - Prompt input

    /// The serving path's template input, read back through `tojson`.
    private static func renderedHistoryArguments(modelType: String) throws -> String {
        let body = try Self.body(arguments: Self.nullArguments)
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let input = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, modelType: modelType,
            templateControls: ProviderLoop.extractChatTemplateControls(from: body))
        let probe = try Template(
            "{%- for m in messages -%}{%- if m.tool_calls is defined -%}{%- for tc in m.tool_calls -%}"
                + "{{ tc.function.arguments | tojson }};{%- endfor -%}{%- endif -%}{%- endfor -%}",
            with: .init(lstripBlocks: true, trimBlocks: true))
        return try probe.render(["messages": try Jinja.Value(any: input.messages)])
            .replacingOccurrences(of: ", ", with: ",").replacingOccurrences(of: ": ", with: ":")
    }

    /// Families on the shared sanitizer: the nulls used to be dropped (keys
    /// removed, array elements compacted). GLM-5.3, MiMo and Flint already
    /// kept them; they stay as guards.
    @Test("history call arguments keep their nulls in the template input",
          arguments: ["gemma4", "qwen3_5", "qwen3_5_moe", "qwen4_exp", "nemotron_h", "gpt_oss",
                      Inkling2ModelIdentity.modelType, "glm5_next", "mimo_v2", "flint"])
    func templateInputKeepsHistoryNulls(modelType: String) throws {
        let rendered = try Self.renderedHistoryArguments(modelType: modelType)
        #expect(rendered.contains(#""deadline":null"#), "\(modelType): \(rendered)")
        #expect(rendered.contains(#""dark-mode":null"#), "\(modelType): \(rendered)")
        #expect(rendered.contains(#""rows":[[false,"Total"],null]"#), "\(modelType): \(rendered)")
        #expect(rendered.contains(#""data":[null,{}]"#), "\(modelType): \(rendered)")
    }
}
