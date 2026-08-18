import SwiftUI

struct PreparationStepView: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    let isCompact: Bool

    var body: some View {
        OnboardingStageScaffold(step: .preparation, isCompact: isCompact) {
            VStack(alignment: .leading, spacing: 13) {
                actions

                Text(preparationDetail)
                    .font(DarkbloomTheme.chivo(10))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.44))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } visual: {
            PreparationSurface(flow: flow, identity: identity)
        }
    }

    private var preparationButtonTitle: String {
        switch flow.preparationPhase {
        case .reservingSpace: "Previewing space check…"
        case .downloading: "Previewing download…"
        case .verifying: "Previewing verification…"
        case .ready: "Continue"
        case .downloadFailed: "Download interrupted"
        }
    }

    @ViewBuilder
    private var actions: some View {
        if flow.preparationPhase == .downloadFailed {
            VStack(alignment: .leading, spacing: 2) {
                OnboardingPrimaryButton(title: "Preview download again", systemImage: "arrow.clockwise") {
                    flow.previewPreparationRetry()
                }
                .keyboardShortcut(.defaultAction)
                OnboardingQuietButton(title: "Run system check", systemImage: "stethoscope") {
                    flow.returnToReadinessForSystemCheck()
                }
            }
        } else {
            OnboardingPrimaryButton(
                title: flow.preparationPhase == .ready ? "Continue" : preparationButtonTitle,
                systemImage: flow.preparationPhase == .ready ? "arrow.right" : nil,
                isWorking: flow.preparationPhase != .ready,
                isDisabled: flow.preparationPhase != .ready
            ) {
                flow.continueToNextStep()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var preparationDetail: String {
        if flow.preparationPhase == .downloadFailed {
            return "Check storage and network access, then resume the verified model download. UI preview only."
        }
        return "Live setup will confirm a compatible model and its exact download size for \(identity.chipName)."
    }
}

private struct PreparationSurface: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Int {
        Int((flow.preparationProgress * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MODEL PREPARATION PREVIEW")
                        .font(DarkbloomTheme.chivo(9, weight: .medium))
                        .tracking(1.05)
                    Text("SIMULATED · no model or files changed")
                        .font(DarkbloomTheme.chivo(10))
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.44))
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(DarkbloomTheme.accent)
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(DarkbloomTheme.nodePale.opacity(0.18))
                    .frame(width: 132, height: 132)
                    .blur(radius: 2)
                Circle()
                    .stroke(DarkbloomTheme.accent.opacity(0.14), lineWidth: 1)
                    .frame(width: 110, height: 110)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(DarkbloomTheme.ink)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            HStack(alignment: .firstTextBaseline) {
                Text(phaseTitle)
                    .font(DarkbloomTheme.chivo(14, weight: .medium))
                Spacer()
                Text("\(percent)%")
                    .font(DarkbloomTheme.chivo(12, weight: .medium))
                    .foregroundStyle(DarkbloomTheme.accent)
                    .monospacedDigit()
            }

            ProgressView(value: flow.preparationProgress)
                .progressViewStyle(.linear)
                .tint(flow.preparationPhase == .downloadFailed ? .orange : DarkbloomTheme.accent)
                .padding(.top, 9)

            HStack {
                Text("Sample catalog model")
                Spacer()
                Text("Size confirmed at setup")
            }
            .font(DarkbloomTheme.chivo(9))
            .foregroundStyle(DarkbloomTheme.ink.opacity(0.4))
            .padding(.top, 7)

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 13)

            HStack(spacing: 15) {
                phasePill("SPACE", complete: flow.preparationPhase != .reservingSpace)
                phasePill(
                    "DOWNLOAD",
                    complete: flow.preparationPhase == .verifying || flow.preparationPhase == .ready
                )
                phasePill("VERIFY", complete: flow.preparationPhase == .ready)
            }
        }
        .padding(25)
        .frame(width: 365, height: 390, alignment: .topLeading)
        .onboardingPanel()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: flow.preparationPhase)
    }

    private var phaseTitle: String {
        switch flow.preparationPhase {
        case .reservingSpace: "Previewing local space check"
        case .downloading: "Previewing verified download"
        case .verifying: "Previewing integrity check"
        case .ready: "Model setup preview complete"
        case .downloadFailed: "Download needs attention"
        }
    }

    private func phasePill(_ title: String, complete: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(complete ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.14))
                .frame(width: 5, height: 5)
            Text(title)
                .font(DarkbloomTheme.chivo(8, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(DarkbloomTheme.ink.opacity(complete ? 0.7 : 0.3))
        }
    }
}
