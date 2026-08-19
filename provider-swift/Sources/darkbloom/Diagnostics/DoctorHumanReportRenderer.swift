import Foundation
import ProviderCore

/// Renders `DoctorRunArtifacts` as the operator-facing plain-text report —
/// extracted verbatim from `Doctor.run()` so the human output format is
/// pinned by tests instead of living untestable inside the command body.
/// Byte-for-byte identical to what `doctor` has always printed.
enum DoctorHumanReportRenderer {
    static func render(_ artifacts: DoctorRunArtifacts) -> String {
        var out: [String] = [
            "darkbloom doctor \(artifacts.version)",
            "Config: \(artifacts.configDescription)",
            "Daemon: \(artifacts.daemonRunning ? "running" : "NOT running — run `darkbloom start`")",
        ]

        // The high-signal diagnosis first (sectioned, with fixes).
        let rendered = DiagnosticReportRenderer.render(artifacts.diagnosis)
        if !rendered.isEmpty { out.append(rendered) }

        // Then the detailed low-level checks.
        out.append("")
        out.append("DETAILED CHECKS")
        for check in artifacts.detailedChecks {
            out.append("  \(check.status.marker) \(check.name): \(check.detail)")
        }

        if let guide = artifacts.bootSecurityGuide {
            out.append("")
            out.append("BOOT SECURITY — ACTION REQUIRED")
            out.append(guide)
        }
        if let support = artifacts.support {
            out.append("")
            out.append("Support")
            out.append("  coordinator: \(support.coordinator)")
            out.append("  serial: \(support.serial)")
            out.append("  auth token: \(support.authTokenPresent ? "present" : "missing")")
            out.append("  mdm enrolled: \(support.mdmEnrolled)")
            out.append("  pid file: \(support.pidFile)")
        }
        return out.joined(separator: "\n")
    }
}
