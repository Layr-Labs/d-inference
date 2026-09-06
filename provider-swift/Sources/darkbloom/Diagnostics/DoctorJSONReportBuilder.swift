import Foundation
import ProviderCore

/// Projects `DoctorRunArtifacts`' check arrays into the `DoctorReport` wire
/// document (schema 1). Pure and total: same checks in, same JSON out.
///
/// The projection ADDS structure the human report doesn't need (stable ids,
/// section grouping, prioritized fixes) but never changes a verdict or a
/// message — one truth, two renderers.
enum DoctorJSONReportBuilder {
    /// Lowercase ASCII-alphanumeric slug, non-alphanumerics collapsed to one
    /// `-`. Stable forever — these ids are wire contract.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(Character(scalar))
                || ("0"..."9").contains(Character(scalar))
            {
                if pendingDash, !out.isEmpty { out.append("-") }
                out.append(String(scalar))
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out
    }

    static func daemonCheck(running: Bool) -> DoctorReport.Check {
        DoctorReport.Check(
            id: "runtime.daemon",
            section: DiagnosticSection.runtime.wireID,
            title: "daemon",
            status: running ? .pass : .warn,
            detail: running ? "running" : "NOT running — run `darkbloom start`",
            advice: running ? nil : "run `darkbloom start`, then re-run `darkbloom doctor`"
        )
    }

    /// Operator diagnosis entries → checks, ids "<section>.<slug>" —
    /// e.g. `attestationKey.se-key-sign-test`.
    static func checks(forDiagnosis diagnosis: [Diagnostic]) -> [DoctorReport.Check] {
        diagnosis.map { d in
            DoctorReport.Check(
                id: "\(d.section.wireID).\(slug(d.name))",
                section: d.section.wireID,
                title: d.name,
                status: d.level,
                detail: d.message,
                advice: d.fix
            )
        }
    }

    /// Detailed low-level checks → checks, ids "<slug>" — e.g. `metal-gpu`.
    static func checks(forDetailedChecks detailed: [DoctorCheck]) -> [DoctorReport.Check] {
        detailed.map { c in
            DoctorReport.Check(
                id: slug(c.name),
                section: c.section,
                title: c.name,
                status: DoctorJSONReportBuilder.level(c.status),
                detail: c.detail,
                advice: nil
            )
        }
    }

    static func level(_ status: CheckStatus) -> DiagnosticLevel {
        switch status {
        case .pass: return .pass
        case .warn: return .warn
        case .fail: return .fail
        }
    }

    /// Build the full report. Order is presentation order — daemon banner,
    /// operator diagnosis, detailed checks — and ids are de-duplicated
    /// deterministically so report consumers can key on them safely.
    static func build(
        version: String,
        daemonRunning: Bool,
        diagnosis: [Diagnostic],
        detailedChecks: [DoctorCheck]
    ) -> DoctorReport {
        var checks = [daemonCheck(running: daemonRunning)]
        checks.append(contentsOf: Self.checks(forDiagnosis: diagnosis))
        checks.append(contentsOf: Self.checks(forDetailedChecks: detailedChecks))
        deduplicateIDs(&checks)
        return DoctorReport(
            version: version,
            checks: checks,
            fixes: fixes(for: checks),
            verdict: verdict(for: checks)
        )
    }

    /// `Identifiable`-id safety: a duplicated id makes SwiftUI's ForEach
    /// collapse rows, so a collision (same section + check name built twice)
    /// gets a numeric suffix rather than silent data loss.
    private static func deduplicateIDs(_ checks: inout [DoctorReport.Check]) {
        var seen: [String: Int] = [:]
        for index in checks.indices {
            let id = checks[index].id
            let count = (seen[id] ?? 0) + 1
            seen[id] = count
            guard count > 1 else { continue }
            checks[index] = DoctorReport.Check(
                id: "\(id)-\(count)",
                section: checks[index].section,
                title: checks[index].title,
                status: checks[index].status,
                detail: checks[index].detail,
                advice: checks[index].advice
            )
        }
    }

    /// Every check carrying advice becomes a fix card; failing checks are
    /// urgent, warnings recommended. Urgent fixes list first (stable).
    /// nil (omitted from the JSON) when nothing needs fixing.
    static func fixes(for checks: [DoctorReport.Check]) -> [DoctorReport.Fix]? {
        let withAdvice = checks.filter { $0.advice != nil }
        let fixes = withAdvice.map { check in
            DoctorReport.Fix(
                id: "fix-\(check.id)",
                check: check.id,
                title: check.title,
                detail: check.advice ?? "",
                priority: check.status == .fail ? .urgent : .recommended
            )
        }
        let urgent = fixes.filter { $0.priority == .urgent }
        let recommended = fixes.filter { $0.priority == .recommended }
        let ordered = urgent + recommended
        return ordered.isEmpty ? nil : ordered
    }

    static func verdict(for checks: [DoctorReport.Check]) -> DoctorReport.Verdict {
        let failures = checks.filter { $0.status == .fail }.count
        let warnings = checks.filter { $0.status == .warn }.count
        return DoctorReport.Verdict(
            status: failures > 0 ? .fail : (warnings > 0 ? .warn : .pass),
            failures: failures,
            warnings: warnings
        )
    }
}
