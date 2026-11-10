import Foundation

enum ClusterConsoleText {
    /// An error as one printable line of bounded length.
    static func bounded(_ error: Error) -> String { bounded(String(describing: error)) }

    static func bounded(_ text: String, maximum: Int = 512) -> String {
        String(text.map { character -> Character in
            character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } ? character : " "
        }.prefix(maximum))
    }

    /// `text` as one printable line of at most `maximum` characters (`bounded`). One that is longer is cut at a word,
    /// never inside a parenthesis, and ends with "…" (the leader's Local Network ✗ cut a line at "(its part is still
    /// running": the pair-2 re-test, R-4).
    static func boundedAtWord(_ text: String, maximum: Int) -> String {
        let line = bounded(text, maximum: .max)
        guard line.count > maximum, maximum > 1 else { return line }
        var kept = line.prefix(maximum - 1)
        if let space = kept.lastIndex(of: " ") { kept = kept[..<space] }
        var depth = 0
        var open: Substring.Index?
        for index in kept.indices {
            switch kept[index] {
            case "(":
                if depth == 0 { open = index }
                depth += 1
            case ")" where depth > 0:
                depth -= 1
                if depth == 0 { open = nil }
            default: break
            }
        }
        if let open { kept = kept[..<open] }
        while let last = kept.last, " ,;:".contains(last) { kept = kept.dropLast() }
        return (kept.isEmpty ? line.prefix(maximum - 1) : kept) + "…"
    }

    /// `2026-10-09T06:45:12Z`.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The first twelve characters of a digest: enough to tell two apart.
    static func short(_ digest: String) -> String { String(digest.prefix(12)) }

    /// An error's words without the Swift case around them: `invalid("Installed local owner …")` reads
    /// `Installed local owner …`. Anything else is kept as it is.
    static func plain(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix("\")"),
              trimmed[..<open].allSatisfy({ $0.isLetter || $0.isNumber }), !trimmed[..<open].isEmpty,
              trimmed[trimmed.index(after: open)...].first == "\"" else { return text }
        let inner = trimmed[trimmed.index(open, offsetBy: 2)..<trimmed.index(trimmed.endIndex, offsetBy: -2)]
        return inner.contains("\"") ? text : String(inner)
    }
}

/// Free text that reaches the snapshot: an error's description, a check's
/// detail. The operations that produce it keep to names and digests, but an
/// error from a library may quote a path or an address, so each such string
/// is passed through the shape rules and the two identifiers always at hand
/// before it is shown, printed or exported.
struct ClusterConsoleFreeText: Sendable {
    let redaction: ClusterDiagnosticRedaction

    init(homeDirectory: String) {
        redaction = .init(identifiers: .init(homeDirectories: [homeDirectory, NSHomeDirectory()], userNames: [NSUserName()]))
    }

    func callAsFunction(_ text: String) -> String { redaction.redact(text) }
    func callAsFunction(_ text: String?) -> String? { text.map(redaction.redact) }
}
