import SwiftUI

struct DiagnosticsVerdictHeader: View {
    let report: DiagnosticReport
    let runState: DiagnosticRunState

    private var presentation: DiagnosticsVerdictPresentation {
        DiagnosticsVerdictPresentation(report: report, runState: runState)
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(presentation.tint.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: presentation.icon)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(presentation.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(DarkbloomTheme.chivo(23))
                    .tracking(-0.4)
                Text(presentation.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            DiagnosticsRunStateView(runState: runState)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }
}

private struct DiagnosticsRunStateView: View {
    let runState: DiagnosticRunState

    var body: some View {
        switch runState {
        case .ready(let lastChecked):
            Text("Checked \(lastChecked.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .running(let completed, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .frame(width: 92)
                Text("\(completed) of \(total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .notStarted:
            Text("No checks have run yet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .unavailable(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(ProductPalette.warning)
                .frame(maxWidth: 210, alignment: .trailing)
        }
    }
}
