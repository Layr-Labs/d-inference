import SwiftUI

struct SetupCompleteStepView: View {
    let identity: MachineIdentity
    let isCompact: Bool
    let onFinish: (OnboardingCompletionChoice) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview
    @State private var bloomIsVisible = false

    var body: some View {
        OnboardingStageScaffold(
            step: .complete,
            title: "Setup preview\nis complete.",
            message: "Choose where to explore next. This UI preview has not changed an account, profile, or provider setting. No model is required to finish setup.",
            isCompact: isCompact
        ) {
            VStack(alignment: .leading, spacing: 13) {
                OnboardingPrimaryButton(title: "Start a chat", systemImage: "bubble.left.and.bubble.right") {
                    onFinish(.startChat)
                }
                .keyboardShortcut(.defaultAction)

                OnboardingQuietButton(title: "Review availability", systemImage: "gauge.with.dots.needle.67percent") {
                    onFinish(.reviewAvailability)
                }

                Text("Sample handoff only. Live setup will reconcile account, verification profile, hardware trust, and network availability. Choose a model later when you want to run private AI.")
                    .font(DarkbloomTheme.chivo(11))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.58))
            }
        } visual: {
            VerifiedMachineSurface(
                identity: identity,
                bloomIsVisible: bloomIsVisible,
                reduceMotion: reduceMotion
            )
        }
        .onAppear {
            guard !reduceMotion, !isCapturingPreview else {
                bloomIsVisible = true
                return
            }
            withAnimation(.spring(response: 0.62, dampingFraction: 0.8)) {
                bloomIsVisible = true
            }
        }
    }
}

private struct VerifiedMachineSurface: View {
    let identity: MachineIdentity
    let bloomIsVisible: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(DarkbloomTheme.accent.opacity(0.12))
                .frame(width: bloomIsVisible ? 360 : 70, height: bloomIsVisible ? 360 : 70)
                .blur(radius: bloomIsVisible ? 34 : 4)

            Circle()
                .fill(.white.opacity(0.72))
                .frame(width: bloomIsVisible ? 265 : 90, height: bloomIsVisible ? 265 : 90)
                .blur(radius: 7)

            VStack(spacing: 18) {
                Image(systemName: identity.formFactor.symbolName)
                    .font(.system(size: 112, weight: .ultraLight))
                    .foregroundStyle(DarkbloomTheme.ink)

                VStack(spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(DarkbloomTheme.accent)
                            .frame(width: 7, height: 7)
                        Text("UI SETUP COMPLETE")
                            .font(DarkbloomTheme.chivo(10, weight: .medium))
                            .tracking(1.1)
                    }
                    Text(identity.displayName)
                        .font(DarkbloomTheme.chivo(20, weight: .medium))
                    Text(identity.chipName)
                        .font(DarkbloomTheme.chivo(12))
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.5))
                }
            }
            .padding(26)
            .frame(width: 320, height: 350)
            .onboardingPanel()
            .scaleEffect(bloomIsVisible ? 1 : 0.92)
            .opacity(bloomIsVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .spring(response: 0.72, dampingFraction: 0.82),
            value: bloomIsVisible
        )
    }
}
