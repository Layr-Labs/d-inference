// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// A request renders its prompt on a 512 KiB stack, and a template that formats a tool schema with a recursive
/// macro (Gemma 4's `format_parameters`) recurses in the Jinja interpreter once per schema level. The tokenizer
/// renders on a stack of its own (`TemplateRenderStack`), so the deepest schema a request may carry renders.
@Suite("Local tokenizer deep tool schema")
struct LocalTokenizerDeepToolSchemaTests {
    /// The prompt token cache on, then off. On, its background comparison renders the request again on a task of
    /// its own, outside the tokenizer's entry points.
    private static let promptCacheEnvironments: [[String: String]] = [[:], ["DARKBLOOM_TTFT_PROMPT_CACHE": "0"]]

    /// What Gemma 4's `format_parameters` does to a nested schema, reduced to the recursion. A request without the
    /// probed schema renders nothing, which is what the cache's load-time self-check sends.
    private static let recursiveTemplate = """
        {%- macro format_schema(schema) -%}
        {{- schema['type'] -}}
        {%- if schema['items'] is defined -%}<{{- format_schema(schema['items']) -}}>{%- endif -%}
        {%- endmacro -%}
        {%- if tools and tools[0]['function']['parameters']['properties']['a'] is defined -%}
        {{- format_schema(tools[0]['function']['parameters']['properties']['a']) -}}
        {%- endif -%}
        """

    /// The request-sized stack: a Swift concurrency cooperative thread's.
    private static let requestStackBytes = 512 << 10

    /// A character-level tokenizer whose chat template is the recursive one, with the added token the prompt token
    /// cache needs to cut a prompt at.
    private func tokenizerDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deep-tool-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let config: [String: Any] = [
            "tokenizer_class": "GemmaTokenizer", "unk_token": "<unk>",
        ]
        var vocabulary: [String: Int] = ["<unk>": 0]
        for value in 32...126 { vocabulary[String(UnicodeScalar(value)!)] = value - 31 }
        let data: [String: Any] = [
            "model": ["type": "BPE", "vocab": vocabulary, "merges": [String](), "unk_token": "<unk>"],
            "decoder": ["type": "Fuse"],
            "added_tokens": [["id": 96, "content": "<turn>", "special": true] as [String: Any]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(
            to: directory.appendingPathComponent("tokenizer_config.json"))
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(Self.recursiveTemplate.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        return directory
    }

    private func tools(nesting levels: Int) -> [[String: any Sendable]] {
        var schema: [String: any Sendable] = ["type": "string"]
        for _ in 0..<levels { schema = ["type": "array", "items": schema] }
        let parameters: [String: any Sendable] = ["type": "object", "properties": ["a": schema] as [String: any Sendable]]
        let function: [String: any Sendable] = ["name": "probe", "parameters": parameters]
        return [["type": "function", "function": function]]
    }

    private func expected(nesting levels: Int) -> String {
        String(repeating: "array<", count: levels) + "string" + String(repeating: ">", count: levels)
    }

    /// `body`'s result from a thread with a request-sized stack.
    private func onRequestStack<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> Value {
        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = Self.requestStackBytes
        thread.start()
        done.wait()
        return box.value!
    }

    private final class ResultBox<Value>: @unchecked Sendable { var value: Value? }

    /// Without the render stack it needs more than that stack holds in a debug build.
    @Test("the deepest schema a request may carry renders from a request-sized stack", arguments: promptCacheEnvironments)
    func deepestRequestSchemaRenders(environment: [String: String]) async throws {
        let levels = 64
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader(environment: environment).load(from: directory)
        let tools = tools(nesting: levels)
        #expect(PromptPreparationProbe.promptCacheIsActive(tokenizer) == PromptTokenCachePolicy.isEnabled(environment: environment))
        let messages: [[String: any Sendable]] = [["role": "user", "content": "hi"]]

        let plain = onRequestStack {
            Result { try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: nil) }
        }
        #expect(tokenizer.decode(tokenIds: try plain.get(), skipSpecialTokens: false) == expected(nesting: levels))

        // The cache-scoped entry point, which renders through `PromptTokenCache` when the cache is on.
        let scoped = onRequestStack {
            Result { () throws -> [Int]? in
                try (tokenizer as? any PromptTokenCaching)?.applyChatTemplate(
                    messages: messages, tools: tools, additionalContext: nil, promptCacheScope: "scope")
            }
        }
        let scopedTokens = try #require(try scoped.get())
        #expect(tokenizer.decode(tokenIds: scopedTokens, skipSpecialTokens: false) == expected(nesting: levels))

        // The cache compares its first prompts with the unchanged path's render on a background task of its own,
        // outside the entry points above. That render, from a request-sized stack, gives the same tokens.
        if let cache = (tokenizer as? any PromptTokenCaching)?.promptTokenCache {
            let compared = onRequestStack { cache.reference(messages: messages, tools: tools, additionalContext: nil) }
            #expect(compared == scopedTokens)
        }
        #expect(PromptPreparationProbe.promptCacheIsActive(tokenizer) == PromptTokenCachePolicy.isEnabled(environment: environment))
    }

    @Test("a shallow schema renders the same tokens as before")
    func shallowSchemaRenders() async throws {
        let directory = try tokenizerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let tokens = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "hi"]], tools: tools(nesting: 2), additionalContext: nil)
        #expect(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == "array<array<string>>")
    }
}
