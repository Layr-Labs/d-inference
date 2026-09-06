import SwiftUI

struct DiagnosticCheckRow: View {
    let check: DiagnosticCheckSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(check.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(check.section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                }
                Text(check.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 12)
        }
    }

    private var icon: String {
        switch check.severity {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch check.severity {
        case .passed: ProductPalette.positive
        case .warning: ProductPalette.warning
        case .failure: ProductPalette.critical
        }
    }
}
