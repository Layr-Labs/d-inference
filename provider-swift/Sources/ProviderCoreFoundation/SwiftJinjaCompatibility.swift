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
    return result
}
