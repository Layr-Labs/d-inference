import Foundation

public func normalizeSwiftJinjaTemplate(_ template: String) -> String {
    var result = template

    // Swift Jinja does not implement whitespace-control markers on comments.
    // Apply the same transformation it uses for expressions and statements.
    result = result.replacingOccurrences(
        of: #"-#\}\s*"#,
        with: "#}",
        options: .regularExpression)
    result = result.replacingOccurrences(
        of: #"\s*\{#-"#,
        with: "{#",
        options: .regularExpression)

    // Swift Jinja keeps a space between a literal opening brace and a
    // whitespace-controlled tag to avoid treating `{{{` as one delimiter.
    // Render the brace as an expression so the requested trim is preserved.
    result = result.replacingOccurrences(
        of: #"\{\s+\{\{-"#,
        with: "{{ '{' -}}{{-",
        options: .regularExpression)
    result = result.replacingOccurrences(
        of: #"\{\s+\{%-"#,
        with: "{{ '{' -}}{%-",
        options: .regularExpression)
    guard result.contains("strftime_now") else { return result }

    // Interpreter.interpret recreates its root environment and overwrites
    // context entries named after built-ins. Bind the private request clock
    // inside that environment, before executing the unchanged model template.
    // No request clock means ordinary built-in behavior (e.g. scan self-check).
    let clock = PromptRenderDate.clockContextKey
    let preamble = "{% if \(clock) is defined %}{% set strftime_now = \(clock) %}{% endif %}"
    guard !result.hasPrefix(preamble) else { return result }

    // All served-template callers enable lstrip_blocks. Preserve its treatment
    // of the first line, which would otherwise follow the injected statement.
    result = result.replacingOccurrences(
        of: #"^[ \t]+(?=\{[#%])"#, with: "", options: .regularExpression)
    // A leading whitespace-control tag must also retain its original effect.
    result = result.replacingOccurrences(
        of: #"^\s+(?=\{[{%]-)"#, with: "", options: .regularExpression)
    return preamble + result
}

/// Blocks of served templates that print a tool-call argument with swift-jinja's
/// plain value rendering, which writes `null` as an empty string (Python's
/// Jinja writes `None`). Earlier tool calls keep their JSON nulls as Jinja
/// `null` (`sanitizeMessageForJinja`), so each block gains a branch that
/// writes `null`, the literal the matching output parser reads back as JSON
/// null. A template without a null leaf renders exactly as before.
///
/// - Gemma 4's `format_argument` macro (call arguments).
/// - The Qwen 3.5 and Nemotron 3.5 Lightning XML parameter value.
///
/// Applied, before `normalizeSwiftJinjaTemplate`, only where the shared
/// sanitizer feeds the template (the serving tokenizer and the render
/// self-check); the managed Nemotron Super contract keeps its own rendering.
let toolArgumentNullRewrites: [(old: String, new: String)] = [
    (
        "{%- macro format_argument(argument, escape_keys=True) -%}\n    {%- if argument is string -%}",
        "{%- macro format_argument(argument, escape_keys=True) -%}\n    {%- if argument is none -%}\n        {{- 'null' -}}\n    {%- elif argument is string -%}"
    ),
    (
        "if args_value is mapping or (args_value is sequence and args_value is not string) else args_value | string %}",
        "if args_value is mapping or (args_value is sequence and args_value is not string) else ('null' if args_value is none else args_value | string) %}"
    ),
]

public func renderingToolArgumentNulls(_ template: String) -> String {
    var result = template
    for rewrite in toolArgumentNullRewrites where result.contains(rewrite.old) {
        result = result.replacingOccurrences(of: rewrite.old, with: rewrite.new)
    }
    return result
}
