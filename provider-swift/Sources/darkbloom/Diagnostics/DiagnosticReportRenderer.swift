import Foundation
import ProviderCore

/// Renders a list of `Diagnostic`s as the sectioned, operator-readable report
/// printed by `darkbloom doctor`. Pure string production so it can be
/// snapshot-tested.
enum DiagnosticReportRenderer {
    static func render(_ diagnostics: [Diagnostic]) -> String {
        var out: [String] = []
        for section in DiagnosticSection.allCases {
            let items = diagnostics.filter { $0.section == section }
            guard !items.isEmpty else { continue }
            out.append("")
            out.append(section.title)
            for d in items {
                out.append("  \(d.level.marker) \(d.name) — \(d.message)")
                if let fix = d.fix, !fix.isEmpty {
                    out.append("         ↳ fix: \(fix)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Overall verdict: any fail → fail; with `strict`, any warn also → fail.
    static func hasFailure(_ diagnostics: [Diagnostic], strict: Bool) -> Bool {
        if diagnostics.contains(where: { $0.level == .fail }) { return true }
        if strict && diagnostics.contains(where: { $0.level == .warn }) { return true }
        return false
    }
}
