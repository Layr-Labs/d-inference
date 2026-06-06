import Foundation

/// Pure semver comparison for the version diagnostic. A provider below the
/// coordinator's minimum version is rejected from routing (RuntimeVerified=false)
/// — the operator needs to know that's why they aren't earning.
public enum VersionDiagnostic {
    /// Parses a dotted version ("0.5.15", "v1.2.3", "1.2.3-beta") into
    /// comparable integer components, ignoring any leading "v" and pre-release
    /// suffix. Returns nil on garbage.
    public static func parse(_ version: String) -> [Int]? {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        // Drop pre-release/build metadata.
        if let dash = v.firstIndex(of: "-") { v = String(v[..<dash]) }
        if let plus = v.firstIndex(of: "+") { v = String(v[..<plus]) }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// Returns -1 if a<b, 0 if equal, 1 if a>b. Unparseable versions sort as
    /// "unknown" and compare equal (caller treats that as a soft pass).
    public static func compare(_ a: String, _ b: String) -> Int {
        guard let pa = parse(a), let pb = parse(b) else { return 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Builds the version diagnostic. `minimum`/`latest` may be empty/unknown.
    public static func diagnose(current: String, minimum: String?, latest: String?) -> Diagnostic {
        if let minimum, !minimum.isEmpty, parse(minimum) != nil, parse(current) != nil,
           compare(current, minimum) < 0 {
            return Diagnostic(
                section: .version, name: "minimum version", level: .fail,
                message: "running \(current); the coordinator requires ≥ \(minimum). You will not be trusted until you update.",
                fix: "`darkbloom update` (or enable `auto_update` in provider.toml).")
        }
        if let latest, !latest.isEmpty, parse(latest) != nil, parse(current) != nil,
           compare(current, latest) < 0 {
            return Diagnostic(
                section: .version, name: "up to date", level: .warn,
                message: "running \(current); latest is \(latest).",
                fix: "`darkbloom update` to pick up fixes.")
        }
        return Diagnostic(
            section: .version, name: "up to date", level: .pass,
            message: "running \(current).",
            fix: nil)
    }
}
