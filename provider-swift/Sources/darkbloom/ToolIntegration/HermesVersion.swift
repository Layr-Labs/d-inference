import Foundation

/// What Darkbloom's Hermes block needs from the installed Hermes.
enum HermesVersion {
    /// `key_cmd`, which Hermes reads Darkbloom's key with, came in Hermes v0.20.2, released as tag v2026.8.16
    /// (NousResearch/hermes-agent#86891). An older Hermes sends its no-key placeholder, and Darkbloom answers 401.
    static let keyCommandSince = [0, 20, 2]
    static let keyCommandSinceRelease = [2026, 8, 16]

    /// The version on `hermes --version`'s first line (`Hermes Agent v0.23.0+12 (2026.9.24)`): the semantic one, else
    /// the release date (a source checkout prints `git.<sha>` in its place); nil when the line names neither.
    static func parse(_ output: String) -> [Int]? {
        let firstLine = output.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        for word in firstLine.split(whereSeparator: { " ()".contains($0) }) {
            let fields = word.drop { $0 == "v" }.prefix { $0 != "+" }.split(separator: ".", omittingEmptySubsequences: false)
            let parts = fields.compactMap { Int($0) }
            if fields.count == 3, parts.count == 3 { return parts }
        }
        return nil
    }

    /// The one line `darkbloom --hermes` prints when the installed Hermes predates `key_cmd`; nil when it doesn't, or
    /// when its version can't be read. A release date (a first number of 2000 or more) compares with v0.20.2's.
    static func keyCommandWarning(versionOutput: String) -> String? {
        guard let version = parse(versionOutput) else { return nil }
        let since = version[0] >= 2000 ? keyCommandSinceRelease : keyCommandSince
        guard version.lexicographicallyPrecedes(since) else { return nil }
        return "Hermes v\(version.map(String.init).joined(separator: ".")) is older than v0.20.2 and can't read "
            + "Darkbloom's key (`key_cmd`), so Darkbloom will refuse its requests; update it with `hermes update`."
    }
}
