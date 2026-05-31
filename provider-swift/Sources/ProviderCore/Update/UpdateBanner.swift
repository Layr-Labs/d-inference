/// UpdateBanner -- non-blocking pre-command update check.
///
/// Hits `${coordinator}/api/version` with a short timeout. If a newer
/// version is published, prints a one-line stderr banner and returns;
/// any failure (timeout, parse error, no banner update) is swallowed
/// silently so the CLI start-up cost is bounded.

import Foundation

public enum UpdateBanner: Sendable {

    /// Run the version check and (best-effort) print a banner. The whole
    /// thing has a configurable hard timeout. Errors are never propagated.
    public static func run(
        coordinatorURL: String,
        currentVersion: String = ProviderCore.version,
        timeout: TimeInterval = 2.0
    ) async {
        let baseURL = coordinatorHTTPBase(coordinatorURL)
        guard let url = URL(string: "\(baseURL)/api/version") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        let payload: VersionPayload
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            payload = try JSONDecoder().decode(VersionPayload.self, from: data)
        } catch {
            return
        }

        guard let latest = payload.version,
              !latest.isEmpty,
              latest != currentVersion,
              isNewerSemver(latest, than: currentVersion)
        else { return }

        printBanner(current: currentVersion, latest: latest, changelog: payload.changelog ?? "")
    }

    // MARK: - Internals

    struct VersionPayload: Decodable {
        let version: String?
        let changelog: String?
    }

    /// Return true if `lhs` is strictly newer than `rhs` under the rules:
    ///   - both are split on '.', non-numeric pre-release tags compared
    ///     lexicographically.
    ///   - "0.5.0" > "0.4.10" (numeric comparison, not lexicographic).
    /// Internal so we can unit-test without a network.
    static func isNewerSemver(_ lhs: String, than rhs: String) -> Bool {
        let l = parts(lhs)
        let r = parts(rhs)
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        // Strip pre-release / build metadata (e.g. "0.5.0-rc1" -> "0.5.0").
        let stripped = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        return stripped.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func printBanner(current: String, latest: String, changelog: String) {
        let header = "Update available: \(current) → \(latest)"
        var lines: [String] = []
        lines.append("")
        lines.append("  ╭──────────────────────────────────────────────╮")
        lines.append("  │  \(pad(header, to: 44))│")
        let snippet = changelog.split(separator: "\n").prefix(2)
        for line in snippet {
            let s = String(line)
            let trimmed = s.count > 42 ? String(s.prefix(39)) + "..." : s
            lines.append("  │  \(pad(trimmed, to: 44))│")
        }
        lines.append("  │                                              │")
        lines.append("  │  Run: darkbloom update                       │")
        lines.append("  ╰──────────────────────────────────────────────╯")
        lines.append("")

        let banner = lines.joined(separator: "\n") + "\n"
        if let data = banner.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private static func pad(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }
}
