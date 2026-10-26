// Copyright © 2026 Eigen Labs.
//
// Linear-time forms of quadratic chat-template loops.
//
// Two served templates scan the message list once per message. Gemma 4 walks
// back over every earlier message to find the previous non-tool role, and
// forward over every later message after each tool call; GPT-OSS walks
// forward over every later message after each tool call. swift-jinja builds a
// loop context per iteration, so a 1,600-message agent history renders in
// 0.25-0.72 s on an M3 Ultra, on every request. Each rewrite replaces a block
// matched verbatim with a form that renders the same text: the previous
// non-tool role is tracked while the main loop runs, the tool-response scan
// stops at the first non-tool message (later iterations only skip), and the
// last final assistant message is located once.
//
// Only the prompt token cache renders through the rewritten template, and it
// compares that render with the unchanged template at load and in sampled
// background checks (`PromptTokenCache`). `DARKBLOOM_TTFT_TEMPLATE_LOOPS=0`
// keeps the template as served.

import Foundation

enum ChatTemplateLoopRewrites {
    static let environmentKey = "DARKBLOOM_TTFT_TEMPLATE_LOOPS"

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        return !["0", "false", "off", "no"].contains(raw)
    }

    struct Rewrite: Sendable {
        let name: String
        /// Every old block must occur exactly once.
        let replacements: [(old: String, new: String)]
        /// Variables the new blocks introduce; the template must not use them.
        let introducedNames: [String]

        func apply(to template: String) -> String? {
            guard introducedNames.allSatisfy({ !template.contains($0) }) else { return nil }
            var result = template
            for (old, new) in replacements {
                let parts = result.components(separatedBy: old)
                guard parts.count == 2 else { return nil }
                result = parts[0] + new + parts[1]
            }
            return result
        }
    }

    /// The template with every rewrite whose blocks it contains, and the
    /// rewrites' names. Blocks are matched after `normalizeSwiftJinjaTemplate`.
    static func apply(to template: String) -> (template: String, applied: [String]) {
        var result = template
        var applied: [String] = []
        for rewrite in all {
            guard let rewritten = rewrite.apply(to: result) else { continue }
            result = rewritten
            applied.append(rewrite.name)
        }
        return (result, applied)
    }

    static let all = [gemma4PreviousTurnRole, gemma4ToolResponseScan, gptOSSFutureFinalScan]

    /// `prev_nt.role` is the role of the nearest earlier non-tool message.
    /// Every non-tool message passes this point, so the role recorded by the
    /// previous one is that message's role. Only `prev_nt.role` is read later.
    static let gemma4PreviousTurnRole = Rewrite(
        name: "gemma4-previous-turn-role",
        replacements: [
            (
                old: """
                    {%- set prev_nt = namespace(role=None, found=false) -%}
                        {%- if loop.index0 > 0 -%}
                            {%- for j in range(loop.index0 - 1, -1, -1) -%}
                                {%- if not prev_nt.found -%}
                                    {%- if loop_messages[j]['role'] != 'tool' -%}
                                        {%- set prev_nt.role = loop_messages[j]['role'] -%}
                                        {%- set prev_nt.found = true -%}
                                    {%- endif -%}
                                {%- endif -%}
                            {%- endfor -%}
                        {%- endif -%}
                    """,
                new: """
                    {%- set prev_nt = namespace(role=ns_prev_nt.role) -%}
                        {%- set ns_prev_nt.role = message['role'] -%}
                    """),
            (
                old: """
                    {%- for message in loop_messages -%}
                        {%- if message['role'] != 'tool' -%}
                    """,
                new: """
                    {%- set ns_prev_nt = namespace(role=None) -%}
                    {%- for message in loop_messages -%}
                        {%- if message['role'] != 'tool' -%}
                    """),
        ],
        introducedNames: ["ns_prev_nt"])

    /// Once `ns_tool_scan.stopped` is set, every later iteration takes the
    /// empty first branch, so stopping there renders the same text.
    static let gemma4ToolResponseScan = Rewrite(
        name: "gemma4-tool-response-scan",
        replacements: [(
            old: """
                {%- for k in range(loop.index0 + 1, loop_messages | length) -%}
                                    {%- if ns_tool_scan.stopped -%}
                                    {%- elif loop_messages[k]['role'] != 'tool' -%}
                                        {%- set ns_tool_scan.stopped = true -%}
                """,
            new: """
                {%- for k in range(loop.index0 + 1, loop_messages | length) -%}
                                    {%- if ns_tool_scan.stopped -%}
                                    {%- elif loop_messages[k]['role'] != 'tool' -%}
                                        {%- set ns_tool_scan.stopped = true -%}{%- break -%}
                """)],
        introducedNames: [])

    /// A later final assistant message exists exactly when the last one in
    /// the list comes after this message (`loop.index` is the next index).
    static let gptOSSFutureFinalScan = Rewrite(
        name: "gpt-oss-future-final-scan",
        replacements: [
            (
                old: """
                    {%- set future_final_message = namespace(found=false) %}
                                {%- for future_message in loop_messages[loop.index:] %}
                                    {%- if future_message.role == 'assistant' and "tool_calls" not in future_message %}
                                        {%- set future_final_message.found = true %}
                                    {%- endif %}
                                {%- endfor %}
                    """,
                new: """
                    {%- set future_final_message = namespace(found=ns_last_final.index >= loop.index) %}
                    """),
            (
                old: """
                    {%- set last_tool_call = namespace(name=none) %}
                    {%- for message in loop_messages -%}
                    """,
                new: """
                    {%- set last_tool_call = namespace(name=none) %}
                    {%- set ns_last_final = namespace(index=-1) %}
                    {%- for future_message in loop_messages %}
                        {%- if future_message.role == 'assistant' and "tool_calls" not in future_message %}
                            {%- set ns_last_final.index = loop.index0 %}
                        {%- endif %}
                    {%- endfor %}
                    {%- for message in loop_messages -%}
                    """),
        ],
        introducedNames: ["ns_last_final"])
}
