import SwiftUI

struct ResumeSetupCard: View {
    let draft: OnboardingDraft
    let showsPreviewChrome: Bool
    let onResume: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("SETUP IN PROGRESS", systemImage: "clock.arrow.circlepath")
                .font(DarkbloomTheme.chivo(9, weight: .medium))
                .tracking(1.05)
                .foregroundStyle(DarkbloomTheme.accent)

            Text("Finish setting up this Mac")
                .font(DarkbloomTheme.chivo(20, weight: .medium))
                .tracking(-0.35)
                .foregroundStyle(DarkbloomTheme.ink)
                .padding(.top, 11)

            Text(draft.progressLabel)
                .font(DarkbloomTheme.chivo(12, weight: .medium))
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.58))
                .padding(.top, 7)

            Text(progressDetail)
                .font(DarkbloomTheme.chivo(11))
                .lineSpacing(3)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            HStack(spacing: 18) {
                OnboardingPrimaryButton(
                    title: "Resume setup",
                    systemImage: "arrow.right",
                    accessibilityIdentifier: "welcome.resume-setup",
                    action: onResume
                )
                .keyboardShortcut(.defaultAction)

                OnboardingQuietButton(
                    title: "Start Over",
                    systemImage: "arrow.counterclockwise",
                    accessibilityIdentifier: "welcome.start-over",
                    action: onStartOver
                )
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(maxWidth: 370, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DarkbloomTheme.accent.opacity(0.14), lineWidth: 1)
                }
        }
        .shadow(color: DarkbloomTheme.accent.opacity(0.08), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
    }

    private var progressDetail: String {
        if showsPreviewChrome {
            return "Only UI progress is saved. Account, profile, and model status remain sample states in this preview."
        }
        return "Darkbloom saved your place. Resume to recheck account, profile, model, and provider status against this Mac."
    }
}
