import SwiftUI

struct DiagnosticsVerdictPresentation {
    let tint: Color
    let icon: String
    let title: String
    let detail: String

    init(report: DiagnosticReport, runState: DiagnosticRunState) {
        if case .running = runState {
            tint = .secondary
            icon = "arrow.triangle.2.circlepath"
            title = "Checking this Mac…"
            detail = "Reviewing hardware, trust, models, connectivity, and the provider runtime."
            return
        }

        // A live store before its first scan: no truth to judge yet — stay
        // neutral instead of flashing the empty report's "healthy" verdict.
        if case .notStarted = runState {
            tint = .secondary
            icon = "stethoscope"
            title = "Check this Mac"
            detail = "Run the system check to review hardware, trust, models, connectivity, and the provider runtime."
            return
        }

        switch report.overallVerdict {
        case .healthy:
            tint = ProductPalette.positive
            icon = "checkmark.shield.fill"
        case .attention:
            tint = ProductPalette.warning
            icon = "exclamationmark.shield.fill"
        case .blocked:
            tint = ProductPalette.critical
            icon = "xmark.shield.fill"
        }

        title = report.overallVerdict.title
        let unresolvedCount = report.unresolvedChecks.count
        if unresolvedCount == 0 {
            detail = "This Mac is ready for private AI and network work."
        } else {
            detail = "\(unresolvedCount) \(unresolvedCount == 1 ? "check needs" : "checks need") your attention."
        }
    }
}
