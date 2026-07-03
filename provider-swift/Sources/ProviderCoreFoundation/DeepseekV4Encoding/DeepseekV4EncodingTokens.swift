// Copyright © 2026 Eigen Labs.
//
// Special tokens and fixed template text for the DeepSeek-V4 DSML prompt
// encoding, ported verbatim from `encoding_dsv4.py` / the DeepSeek-V4
// encoding README (fetched from
// `huggingface.co/deepseek-ai/DeepSeek-V4-Flash/resolve/main/encoding/`).
// Keep every literal byte-for-byte identical to the reference — the model
// was trained against this exact text.

enum DeepseekV4Tokens {
    static let bos = "<｜begin▁of▁sentence｜>"
    static let eos = "<｜end▁of▁sentence｜>"
    static let thinkingStart = "<think>"
    static let thinkingEnd = "</think>"
    /// The bare DSML markup token (without the surrounding `<`/`>`), matching
    /// `dsml_token` in the reference implementation and
    /// `DSMLToolCallParser.dsmlToken` in the mlx-swift-lm fork's decoder.
    static let dsml = "｜DSML｜"
    static let userPrefix = "<｜User｜>"
    static let assistantPrefix = "<｜Assistant｜>"
    static let latestReminderPrefix = "<｜latest_reminder｜>"

    /// Quick-instruction special tokens keyed by the message's `task` field.
    static let taskTokens: [String: String] = [
        "action": "<｜action｜>",
        "query": "<｜query｜>",
        "authority": "<｜authority｜>",
        "domain": "<｜domain｜>",
        "title": "<｜title｜>",
        "read_url": "<｜read_url｜>",
    ]

    /// Ends with a blank line (two trailing newlines), matching the Python
    /// literal's trailing `"\n\n"` exactly.
    static let reasoningEffortMaxPrefix: String = [
        "Reasoning Effort: Absolute maximum with no shortcuts permitted.",
        "You MUST be very thorough in your thinking and comprehensively decompose the problem to resolve the root cause, rigorously stress-testing your logic against all potential paths, edge cases, and adversarial scenarios.",
        "Explicitly write out your entire deliberation process, documenting every intermediate step, considered alternative, and rejected hypothesis to ensure absolutely no assumption is left unchecked.",
        "",
        "",
    ].joined(separator: "\n")

    /// `<tool_result>{content}</tool_result>` wrapper for tool outputs merged
    /// into a user turn.
    static func toolResult(_ content: String) -> String {
        "<tool_result>\(content)</tool_result>"
    }

    /// The `## Tools` system-prompt block injected when a system/developer
    /// message declares `tools`. `toolSchemas` is the newline-joined,
    /// per-tool JSON produced by `DeepseekV4JSON.toJSON` (see that type's
    /// doc comment for the key-ordering caveat).
    static func toolsBlock(toolSchemas: String) -> String {
        let lines = [
            "## Tools",
            "",
            "You have access to a set of tools to help answer the user's question. You can invoke tools by writing a \"<\(dsml)tool_calls>\" block like the following:",
            "",
            "<\(dsml)tool_calls>",
            "<\(dsml)invoke name=\"$TOOL_NAME\">",
            "<\(dsml)parameter name=\"$PARAMETER_NAME\" string=\"true|false\">$PARAMETER_VALUE</\(dsml)parameter>",
            "...",
            "</\(dsml)invoke>",
            "<\(dsml)invoke name=\"$TOOL_NAME2\">",
            "...",
            "</\(dsml)invoke>",
            "</\(dsml)tool_calls>",
            "",
            "String parameters should be specified as is and set `string=\"true\"`. For all other types (numbers, booleans, arrays, objects), pass the value in JSON format and set `string=\"false\"`.",
            "",
            "If thinking_mode is enabled (triggered by \(thinkingStart)), you MUST output your complete reasoning inside \(thinkingStart)...\(thinkingEnd) BEFORE any tool calls or final response.",
            "",
            "Otherwise, output directly after \(thinkingEnd) with tool calls or final response.",
            "",
            "### Available Tool Schemas",
            "",
            toolSchemas,
            "",
            "You MUST strictly follow the above defined tool name and parameter schemas to invoke tool calls.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// `<｜DSML｜invoke name="...">\n{parameters}\n</｜DSML｜invoke>`.
    static func toolCallInvoke(name: String, parametersBlock: String) -> String {
        "<\(dsml)invoke name=\"\(name)\">\n\(parametersBlock)\n</\(dsml)invoke>"
    }

    /// `<｜DSML｜tool_calls>\n{invokes}\n</｜DSML｜tool_calls>`.
    static func toolCallsBlock(invokes: String) -> String {
        "<\(dsml)tool_calls>\n\(invokes)\n</\(dsml)tool_calls>"
    }

    /// `<｜DSML｜parameter name="..." string="true|false">value</｜DSML｜parameter>`.
    static func parameter(name: String, isString: Bool, value: String) -> String {
        "<\(dsml)parameter name=\"\(name)\" string=\"\(isString ? "true" : "false")\">\(value)</\(dsml)parameter>"
    }
}
