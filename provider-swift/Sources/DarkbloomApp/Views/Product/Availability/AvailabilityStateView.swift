import SwiftUI

struct AvailabilityStateView: View {
    enum Kind {
        case loading
        case malformed(message: String, issues: [AvailabilityPolicySourceIssue])
    }

    let kind: Kind
    let onRunSystemCheck: () -> Void

    var body: some View {
        Group {
            switch kind {
            case .loading:
                VStack(spacing: 13) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading availability…")
                        .font(.system(size: 13, weight: .medium))
                    Text("Loading the local provider configuration and runtime observation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .malformed(let message, let issues):
                ContentUnavailableView {
                    Label("Schedule needs repair", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    VStack(spacing: 8) {
                        Text(message)
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Text(AvailabilityPresentation.sourceIssueMessage(issue))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } actions: {
                    Button("Run System Check", systemImage: "stethoscope") {
                        onRunSystemCheck()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .multilineTextAlignment(.center)
    }
}
