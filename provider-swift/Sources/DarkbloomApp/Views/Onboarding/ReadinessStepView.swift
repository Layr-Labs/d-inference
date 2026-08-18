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

    private var items: [(String, String)] {
        [
            ("Apple silicon", appleSiliconDetail),
            ("macOS", "Sonoma or later"),
            ("Secure Enclave", "Available for private identity"),
            ("Unified memory", memoryDetail),
            ("Available storage", storageDetail),
            ("Network", networkDetail),
        ]
    }

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
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    SetupStatusRow(title: item.0, detail: item.1, state: state(for: index))
                }
            }

            Spacer(minLength: 5)

            Text("UI preview only · the live setup connector will rerun every check before continuing.")
                .font(DarkbloomTheme.chivo(9))
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
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
        case .unsupportedMac, .insufficientMemory, .offline: "NEEDS ATTENTION"
        }
    }

    private var statusColor: Color {
        flow.readinessPhase.allowsContinuation ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.58)
    }

    private var appleSiliconDetail: String {
        flow.readinessPhase == .unsupportedMac ? "Apple silicon is required" : (identity.isDetected ? identity.chipName : "Detecting this Mac")
    }

    private var memoryDetail: String {
        if flow.readinessPhase == .insufficientMemory { return "8 GB minimum · More memory required" }
        let detected = MachineFactsFormatter.memory(identity.physicalMemoryBytes)
        return detected == "—" ? "8 GB minimum" : "8 GB minimum · \(detected) detected"
    }

    private var storageDetail: String {
        if flow.readinessPhase == .lowStorage { return "Exact requirement is checked when you choose a model" }
        return MachineFactsFormatter.storageSummary(total: nil, available: identity.storageAvailableBytes)
    }

    private var networkDetail: String {
        flow.readinessPhase == .offline ? "Connect to the internet and check again" : "Connection available"
    }

    private func state(for index: Int) -> SetupItemState {
        if flow.readinessPhase == .lowStorage, flow.readinessPhase.issueItemIndex == index {
            return .advisory
        }
        if flow.readinessPhase.issueItemIndex == index { return .issue }
        if index < flow.readinessCompletedCount { return .complete }
        if flow.readinessPhase == .checking, index == flow.readinessCompletedCount { return .working }
        return .waiting
    }
}
