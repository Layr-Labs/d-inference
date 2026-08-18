import SwiftUI

struct DiagnosticChecksSection: View {
    let report: DiagnosticReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProductSectionHeader("All checks", detail: "No prompt or response content is collected")

            VStack(spacing: 0) {
                if !report.unresolvedChecks.isEmpty {
                    ForEach(Array(report.unresolvedChecks.enumerated()), id: \.element.id) { index, check in
                        DiagnosticCheckRow(check: check)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)

                        if index < report.unresolvedChecks.count - 1 {
                            Divider().padding(.leading, 50)
                        }
                    }

                    Divider()
                }

                DisclosureGroup("\(passedChecks.count) checks passed") {
                    ForEach(Array(passedChecks.enumerated()), id: \.element.id) { index, check in
                        DiagnosticCheckRow(check: check)
                            .padding(.vertical, 10)
                        if index < passedChecks.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                    .padding(.top, 7)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(16)
            }
            .productSurface()
        }
    }

    private var passedChecks: [DiagnosticCheckSummary] {
        report.checks.filter { $0.severity == .passed }
    }
}
