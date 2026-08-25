import Foundation
import ProviderCoreFoundation

/// Strict SemVer 2 comparison for the version diagnostic. A provider below the
/// coordinator's minimum version is rejected from routing (RuntimeVerified=false)
/// — the operator needs to know that's why they aren't earning.
public enum VersionDiagnostic {
    public static func parse(_ version: String) -> SemanticVersion? {
        SemanticVersion(version)
    }

    /// Returns -1 if a<b, 0 if equal, 1 if a>b. Unparseable versions sort as
    /// "unknown" and compare equal (caller treats that as a soft pass).
    public static func compare(_ a: String, _ b: String) -> Int {
        guard let pa = parse(a), let pb = parse(b) else { return 0 }
        if pa == pb { return 0 }
        return pa < pb ? -1 : 1
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
