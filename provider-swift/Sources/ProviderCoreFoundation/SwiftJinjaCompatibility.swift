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
