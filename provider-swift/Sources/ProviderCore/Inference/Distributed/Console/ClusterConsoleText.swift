import Foundation

enum ClusterConsoleText {
    /// An error as one printable line of bounded length.
    static func bounded(_ error: Error) -> String { bounded(String(describing: error)) }

    static func bounded(_ text: String, maximum: Int = 512) -> String {
        String(text.map { character -> Character in
            character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } ? character : " "
        }.prefix(maximum))
    }

    /// `2026-10-09T06:45:12Z`.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The first twelve characters of a digest: enough to tell two apart.
    static func short(_ digest: String) -> String { String(digest.prefix(12)) }
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
