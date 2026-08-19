import SwiftUI

struct VerificationStepView: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    let isCompact: Bool

    var body: some View {
        OnboardingStageScaffold(step: .verification, isCompact: isCompact) {
            VStack(alignment: .leading, spacing: 13) {
                actions
                Text(guidance)
                    .font(DarkbloomTheme.chivo(11))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } visual: {
            VerificationSurface(flow: flow, identity: identity)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.verificationPhase {
        case .hardwareTrusted:
            OnboardingPrimaryButton(title: "Finish setup", systemImage: "arrow.right") {
                flow.continueToNextStep()
            }
            .keyboardShortcut(.defaultAction)
        case .profileDetected, .enrollmentPending, .trustPending:
            OnboardingPrimaryButton(title: workingTitle, isWorking: true, isDisabled: true, action: {})
        case .checkInDelayed:
            recoveryActions(primaryTitle: "Try check-in again", primarySymbol: "arrow.clockwise") {
                Task { await flow.retryVerification() }
            }
        case .trustFailed:
            recoveryActions(primaryTitle: "Run system check", primarySymbol: "stethoscope") {
                Task { await flow.retryVerification() }
            }
        case .offline:
            recoveryActions(primaryTitle: "Try again", primarySymbol: "arrow.clockwise") {
                Task { await flow.retryVerification() }
            }
        }
    }

    private func recoveryActions(
        primaryTitle: String,
        primarySymbol: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            OnboardingPrimaryButton(title: primaryTitle, systemImage: primarySymbol, action: action)
                .keyboardShortcut(.defaultAction)
            HStack(spacing: 16) {
                OnboardingQuietButton(title: "Reopen System Settings", systemImage: "gear") {
                    flow.returnToEnrollmentForSettings()
                }
                OnboardingQuietButton(title: "Download profile again", systemImage: "arrow.down.circle") {
                    flow.returnToEnrollmentForDownload()
                }
            }
        }
    }

    private var workingTitle: String {
        switch flow.verificationPhase {
        case .profileDetected: "Starting enrollment…"
        case .enrollmentPending: "Waiting for check-in…"
        case .trustPending: "Verifying security…"
        default: "Verifying…"
        }
    }

    private var guidance: String {
        switch flow.verificationPhase {
        case .profileDetected:
            "The profile was detected locally. Darkbloom is starting the separate server enrollment check."
        case .enrollmentPending:
            "Initial MDM server check-in may take several minutes. Keep this Mac awake and Darkbloom open."
        case .trustPending:
            "Darkbloom may use APNs to request current SecurityInfo while checking Secure Enclave identity, SIP, and Secure Boot."
        case .hardwareTrusted:
            flow.usesLiveVerification
                ? "Hardware trust is confirmed: the coordinator approved this Mac's Secure Enclave identity, SIP, and Secure Boot via the Darkbloom daemon."
                : "Hardware trust is confirmed for this UI preview. Live setup will require the same checks from the coordinator."
        case .checkInDelayed:
            "Keep this Mac awake and Darkbloom open. If check-in remains delayed, reopen System Settings or re-enroll with a fresh profile."
        case .trustFailed:
            "A security check did not complete. Run the system check again; reinstall the profile if it is no longer valid."
        case .offline:
            "Darkbloom needs outbound network and APNs reachability for enrollment and trust. Reconnect, then try again."
        }
    }
}

private struct VerificationSurface: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity

    private let milestones = [
        ("Profile detected", "Installed locally on this Mac"),
        ("Enrollment check-in", "Waiting for MDM server registration"),
        ("Trust evaluation", "SecurityInfo via APNs, SIP, and Secure Boot"),
        ("Hardware trusted", "Approved by the Darkbloom coordinator"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: identity.formFactor.symbolName)
                    .font(.system(size: 28, weight: .ultraLight))
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName)
                        .font(DarkbloomTheme.chivo(15, weight: .medium))
                    Text("HARDWARE TRUST")
                        .font(DarkbloomTheme.chivo(8, weight: .medium))
                        .tracking(0.9)
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
                }

                Spacer()

                Text(statusLabel)
                    .font(DarkbloomTheme.chivo(8, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(flow.verificationPhase == .hardwareTrusted ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.42))
            }

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.09))
                .frame(height: 1)
                .padding(.vertical, 16)

            VStack(spacing: 4) {
                ForEach(Array(milestones.enumerated()), id: \.offset) { index, milestone in
                    SetupStatusRow(
                        title: milestone.0,
                        detail: detail(for: index, fallback: milestone.1),
                        state: state(for: index)
                    )
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 8))
                Text(flow.usesLiveVerification
                    ? "The running provider reports trust directly from the coordinator."
                    : "Fixture preview · live trust comes from the running provider daemon.")
                    .font(DarkbloomTheme.chivo(9))
            }
            .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
        }
        .padding(25)
        .frame(width: 380, height: 400, alignment: .topLeading)
        .onboardingPanel()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: flow.verificationPhase)
    }

    private var statusLabel: String {
        switch flow.verificationPhase {
        case .hardwareTrusted: "VERIFIED"
        case .checkInDelayed, .trustFailed, .offline: "NEEDS ATTENTION"
        case .profileDetected, .enrollmentPending, .trustPending: "VERIFYING"
        }
    }

    private func state(for index: Int) -> SetupItemState {
        switch (flow.verificationPhase, index) {
        case (_, 0): .complete
        case (.enrollmentPending, 1): .working
        case (.trustPending, 1): .complete
        case (.trustPending, 2): .working
        case (.hardwareTrusted, _): .complete
        case (.checkInDelayed, 1), (.offline, 1), (.trustFailed, 2): .issue
        case (.trustFailed, 1): .complete
        default: .waiting
        }
    }

    private func detail(for index: Int, fallback: String) -> String {
        switch (flow.verificationPhase, index) {
        case (.checkInDelayed, 1): "MDM server check-in is taking longer"
        case (.offline, 1): "The MDM server is unreachable"
        case (.trustFailed, 2): "Security response needs another check"
        default: fallback
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}
