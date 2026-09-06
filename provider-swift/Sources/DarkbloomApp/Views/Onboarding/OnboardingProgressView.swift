import SwiftUI

struct OnboardingProgressView: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 10) {
            Text(step == .complete ? "Setup complete" : "Step \(step.progressOrdinal) of 5")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            ProgressView(value: Double(step.progressOrdinal), total: 5)
                .tint(DarkbloomTheme.accent)
                .frame(width: 88)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup, step \(step.progressOrdinal) of 5: \(step.resumeTitle)")
    }
}
