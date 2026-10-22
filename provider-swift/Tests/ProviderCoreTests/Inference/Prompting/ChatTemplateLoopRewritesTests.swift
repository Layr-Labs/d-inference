// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// A loop rewrite must render exactly the text of the block it replaces.
/// The skeletons embed each rewrite's matched blocks in the surrounding logic
/// of the served template and make every scanned value visible in the
/// output; the live case renders the real templates of local models.
@Suite("Chat-template loop rewrites")
struct ChatTemplateLoopRewritesTests {
    enum Skeleton: String, CaseIterable, CustomTestStringConvertible {
        case gemma4
        case gptOSS

        var testDescription: String { rawValue }

        var expectedRewrites: [String] {
            switch self {
            case .gemma4: ["gemma4-previous-turn-role", "gemma4-tool-response-scan"]
            case .gptOSS: ["gpt-oss-future-final-scan"]
            }
        }

        var source: String {
            switch self {
            case .gemma4:
                let role = ChatTemplateLoopRewrites.gemma4PreviousTurnRole.replacements
                let scan = ChatTemplateLoopRewrites.gemma4ToolResponseScan.replacements[0].old
                return """
                    {%- set loop_messages = messages -%}
                    \(role[1].old)
                        {%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}
                        \(role[0].old)
                        {%- set continue_same_model_turn = (role == 'model' and prev_nt.role == 'assistant') -%}
                        {%- if not continue_same_model_turn -%}{{- '<turn ' + role + '>' -}}{%- endif -%}
                        {{- '[prev=' + (prev_nt.role | string) + ']' -}}
                        {%- if message.get('tool_calls') -%}
                            {%- for tc in message['tool_calls'] -%}{{- '<call ' + tc['function']['name'] + '>' -}}{%- endfor -%}
                            {%- set ns_tool_scan = namespace(stopped=false) -%}
                            \(scan)
                                {%- else -%}
                                    {{- '<result ' + (loop_messages[k]['content'] | string) + '>' -}}
                                {%- endif -%}
                            {%- endfor -%}
                        {%- endif -%}
                        {%- if message['content'] is string -%}{{- message['content'] -}}{%- endif -%}
                        {{- '<end>' -}}
                        {%- endif -%}
                    {%- endfor -%}
                    {%- if add_generation_prompt -%}{{- '<turn model>' -}}{%- endif -%}
                    """
            case .gptOSS:
                let scan = ChatTemplateLoopRewrites.gptOSSFutureFinalScan.replacements
                return """
                    {%- set loop_messages = messages -%}
                    \(scan[1].old)
                        {%- if message.role == 'assistant' -%}
                            {%- if "tool_calls" in message %}
                                \(scan[0].old)
                                {{- '[future=' + (future_final_message.found | string) + ']' }}
                                {%- if message.content and not future_final_message.found %}{{- '<analysis ' + message.content + '>' }}{%- endif %}
                                {{- '<call ' + message.tool_calls[0].function.name + '>' }}
                                {%- set last_tool_call.name = message.tool_calls[0].function.name %}
                            {%- else %}
                                {{- '<final ' + (message.content | string) + '>' }}
                                {%- set last_tool_call.name = none %}
                            {%- endif %}
                        {%- elif message.role == 'tool' -%}
                            {{- '<result ' + (last_tool_call.name | string) + ' ' + (message.content | string) + '>' }}
                        {%- else -%}
                            {{- '<' + message.role + ' ' + (message.content | string) + '>' }}
                        {%- endif -%}
                    {%- endfor -%}
                    """
            }
        }
    }

    @Test("skeletons render identically through the rewrites", arguments: Skeleton.allCases)
    func skeletonsRenderIdentically(skeleton: Skeleton) throws {
        let (rewritten, applied) = ChatTemplateLoopRewrites.apply(to: skeleton.source)
        #expect(applied == skeleton.expectedRewrites)
        let original = try Self.template(skeleton.source)
        let fast = try Self.template(rewritten)
        var generator = ConversationGenerator(seed: UInt64(skeleton.rawValue.utf8.count) &* 977)
        var rendered = 0
        for index in 0..<600 {
            let messages = generator.messages(count: index % 70, wellFormed: index % 3 != 0)
            let expected = Self.render(original, messages: messages)
            #expect(Self.render(fast, messages: messages) == expected, "\(messages)")
            if case .success = expected { rendered += 1 }
        }
        #expect(rendered > 300)
    }

    @Test("rewrites decline templates without their exact blocks or using their names")
    func rewritesDecline() {
        let gemma = Skeleton.gemma4.source
        #expect(ChatTemplateLoopRewrites.apply(to: "{{ messages | length }}").applied.isEmpty)
        // A changed block keeps the template as served.
        let edited = gemma.replacingOccurrences(of: "range(loop.index0 - 1, -1, -1)", with: "range(loop.index0 - 1, -1, -2)")
        #expect(ChatTemplateLoopRewrites.apply(to: edited).applied == ["gemma4-tool-response-scan"])
        // A block that occurs twice is ambiguous.
        let scan = ChatTemplateLoopRewrites.gemma4ToolResponseScan.replacements[0].old
        #expect(ChatTemplateLoopRewrites.gemma4ToolResponseScan.apply(to: scan + scan) == nil)
        // The introduced variable must be new to the template.
        #expect(ChatTemplateLoopRewrites.gemma4PreviousTurnRole.apply(to: gemma + "{{ ns_prev_nt }}") == nil)
        #expect(ChatTemplateLoopRewrites.isEnabled(environment: [:]))
        #expect(!ChatTemplateLoopRewrites.isEnabled(environment: ["DARKBLOOM_TTFT_TEMPLATE_LOOPS": "0"]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(ChatTemplateLoopRewrites.environmentKey))
    }

    /// Runs over real local artifacts: set `PROMPT_TOKEN_CACHE_MODEL_DIRS` to
    /// colon-separated model directories.
    @Test("served templates render identically through the rewrites")
    func servedTemplatesRenderIdentically() throws {
        guard let paths = ProcessInfo.processInfo.environment["PROMPT_TOKEN_CACHE_MODEL_DIRS"] else { return }
        for path in paths.split(separator: ":").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path).appendingPathComponent("chat_template.jinja")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let normalized = normalizeSwiftJinjaTemplate(source)
            let (rewritten, applied) = ChatTemplateLoopRewrites.apply(to: normalized)
            // The served Gemma 4 and GPT-OSS templates carry the scans.
            if normalized.contains("set prev_nt = namespace") || normalized.contains("future_final_message") {
                #expect(!applied.isEmpty, "\(path)")
            }
            guard !applied.isEmpty else { continue }
            let original = try Self.template(normalized)
            let fast = try Self.template(rewritten)
            var generator = ConversationGenerator(seed: 31)
            var rendered = 0
            for index in 0..<400 {
                let messages = generator.messages(count: 2 + index % 90, wellFormed: index % 4 != 0)
                let expected = Self.render(original, messages: messages, tools: generator.tools)
                #expect(Self.render(fast, messages: messages, tools: generator.tools) == expected, "\(path): \(messages)")
                if case .success = expected { rendered += 1 }
            }
            #expect(rendered > 150, "\(path): \(applied)")
        }
    }

    private static func template(_ source: String) throws -> Template {
        try Template(source, with: .init(lstripBlocks: true, trimBlocks: true))
    }

    private static func render(
        _ template: Template, messages: [[String: any Sendable]], tools: [[String: any Sendable]]? = nil
    ) -> Result<String, RenderFailure> {
        do {
            var context: [String: Value] = try [
                "messages": .array(messages.map { try Value(any: $0) }),
                "add_generation_prompt": .boolean(true),
                "bos_token": .string("<bos>"),
            ]
            if let tools { context["tools"] = try .array(tools.map { try Value(any: $0) }) }
            return .success(try template.render(context))
        } catch {
            return .failure(RenderFailure(description: "\(error)"))
        }
    }

    struct RenderFailure: Error, Equatable {
        let description: String
    }
}

/// Random agent histories: tool calls with zero or more results (some with
/// unknown ids), consecutive assistant turns, final answers, optional
/// reasoning, and malformed orders when `wellFormed` is false.
struct ConversationGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed | 1
    }

    let tools: [[String: any Sendable]] = [[
        "type": "function",
        "function": [
            "name": "read_file", "description": "Read a file.",
            "parameters": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Path."] as [String: any Sendable]] as [String: any Sendable],
                "required": ["path"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]]

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    mutating func messages(count: Int, wellFormed: Bool) -> [[String: any Sendable]] {
        var messages: [[String: any Sendable]] = []
        if next(3) == 0 { messages.append(["role": "system", "content": "Be careful."]) }
        messages.append(["role": "user", "content": "Task \(next(100))."])
        var call = 0
        while messages.count < count {
            switch wellFormed ? next(5) : next(7) {
            case 0, 1:
                let id = "call_\(call)"
                call += 1
                var message: [String: any Sendable] = ["role": "assistant", "tool_calls": [[
                    "id": id, "type": "function",
                    "function": ["name": "read_file", "arguments": ["path": "/w/f\(call).swift"] as [String: any Sendable]] as [String: any Sendable],
                ] as [String: any Sendable]]]
                switch next(4) {
                case 0: message["content"] = ""
                case 1: message["content"] = "Looking at f\(call)."
                case 2: message["reasoning_content"] = "Need f\(call)."
                default: break
                }
                messages.append(message)
                for result in 0..<next(3) {
                    messages.append(["role": "tool", "tool_call_id": result == 1 && next(2) == 0 ? "unknown" : id,
                                     "content": "result \(call).\(result)"])
                }
            case 2:
                messages.append(["role": "assistant", "content": "Answer \(next(1000))."])
            case 3:
                messages.append(["role": "user", "content": "Continue \(next(1000))."])
            case 4:
                if let last = messages.last, (last["role"] as? String) == "assistant" {
                    messages.append(["role": "assistant", "content": "Also \(next(1000))."])
                } else {
                    messages.append(["role": "tool", "tool_call_id": "call_\(max(0, call - 1))", "content": "late"])
                }
            case 5:
                messages.append(["role": "tool", "tool_call_id": "orphan", "content": "orphan \(next(10))"])
            default:
                messages.append(["role": "assistant", "content": "", "tool_calls": [] as [any Sendable]])
            }
        }
        return messages
    }
}
