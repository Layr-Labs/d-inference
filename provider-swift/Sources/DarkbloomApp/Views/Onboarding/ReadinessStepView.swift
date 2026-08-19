import SwiftUI

struct ReadinessStepView: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    let isCompact: Bool
    let onExit: () -> Void

    var body: some View {
        OnboardingStageScaffold(step: .readiness, isCompact: isCompact) {
            HStack(spacing: 18) {
                primaryAction
                if flow.readinessPhase != .unsupportedMac,
                   flow.readinessPhase != .insufficientMemory
                {
                    OnboardingQuietButton(title: "Not now", action: onExit)
                }
            }
        } visual: {
            ReadinessSurface(flow: flow, identity: identity)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if flow.readinessPhase.allowsContinuation {
            OnboardingPrimaryButton(
                title: flow.resumeReconciliationState.blocksProgress ? "Rechecking setup…" : "Continue",
                systemImage: flow.canContinue ? "arrow.right" : nil,
                isWorking: flow.resumeReconciliationState.blocksProgress,
                isDisabled: !flow.canContinue
            ) {
                flow.continueToNextStep()
            }
            .keyboardShortcut(.defaultAction)
        } else if flow.readinessPhase == .checking {
            OnboardingPrimaryButton(
                title: "Checking this Mac…",
                isWorking: true,
                isDisabled: true,
                action: {}
            )
        } else if flow.readinessPhase == .unsupportedMac || flow.readinessPhase == .insufficientMemory {
            OnboardingPrimaryButton(title: "Back to welcome", systemImage: "chevron.left", action: onExit)
        } else {
            OnboardingPrimaryButton(title: "Run system check", systemImage: "arrow.clockwise") {
                Task { await flow.retryReadinessChecks() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ReadinessSurface: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: identity.formFactor.symbolName)
                    .font(.system(size: 28, weight: .ultraLight))
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName)
                        .font(DarkbloomTheme.chivo(16, weight: .medium))
                    Text(identity.chipName)
                        .font(DarkbloomTheme.chivo(11))
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.46))
                }

                Spacer()

                Text(statusLabel)
                    .font(DarkbloomTheme.chivo(9, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(statusColor)
            }

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.09))
                .frame(height: 1)
                .padding(.vertical, 13)

            VStack(spacing: 0) {
                ForEach(flow.readinessItems) { item in
                    SetupStatusRow(title: item.title, detail: item.detail, state: item.state)
                }
            }

            Spacer(minLength: 5)

            if let issue = flow.readinessItems.first(where: { $0.state == .issue }),
               let action = issue.action {
                Text(action)
                    .font(DarkbloomTheme.chivo(9, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.86))
                    .lineLimit(3)
            } else {
                Text(flow.usesLiveReadiness
                    ? "Only local hardware, storage, and boot-security prerequisites gate this step."
                    : "Fixture preview · live setup runs darkbloom doctor --json.")
                    .font(DarkbloomTheme.chivo(9))
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
            }
        }
        .padding(23)
        .frame(width: 365, height: 402, alignment: .topLeading)
        .onboardingPanel()
    }

    private var statusLabel: String {
        switch flow.readinessPhase {
        case .checking: "CHECKING"
        case .ready: "READY"
        case .lowStorage: "READY WITH NOTE"
        case .unsupportedMac, .insufficientMemory, .offline, .requirementsFailed,
             .insufficientStorage, .unavailable: "NEEDS ATTENTION"
        }
    }

    private var statusColor: Color {
        flow.readinessPhase.allowsContinuation ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.58)
    }

}
