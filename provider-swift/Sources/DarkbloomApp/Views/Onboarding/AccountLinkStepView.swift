import SwiftUI

struct AccountLinkStepView: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    let isCompact: Bool

    var body: some View {
        OnboardingStageScaffold(step: .account, isCompact: isCompact) {
            VStack(alignment: .leading, spacing: 12) {
                accountStatus
                actions
                Text("Darkbloom product policy requires an account before this Mac can join your fleet. The profile itself is installed by macOS.")
                    .font(DarkbloomTheme.chivo(11))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } visual: {
            AccountLinkSurface(flow: flow, identity: identity)
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        switch flow.accountPhase {
        case .introduction:
            EmptyView()
        case .waitingForApproval:
            Label(
                "Live setup checks approval every \(Int(OnboardingAccountLinkSession.pollInterval)) seconds · codes expire after \(Int(OnboardingAccountLinkSession.lifetime / 60)) minutes",
                systemImage: "safari"
            )
                .accountStatusStyle()
        case .confirming:
            Label("Checking browser approval…", systemImage: "ellipsis")
                .accountStatusStyle()
        case .linked:
            Label("Account connected", systemImage: "checkmark.circle.fill")
                .accountStatusStyle(color: DarkbloomTheme.accent)
        case .expired:
            Label("This code expired. Request a fresh code to continue.", systemImage: "clock.badge.exclamationmark")
                .accountStatusStyle(color: .orange)
        case .unreachable:
            Label("Darkbloom could not be reached. Check your connection and retry.", systemImage: "wifi.exclamationmark")
                .accountStatusStyle(color: .orange)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.accountPhase {
        case .introduction:
            OnboardingPrimaryButton(title: "Preview browser approval", systemImage: "arrow.up.right") {
                flow.showAccountApproval()
            }
            .keyboardShortcut(.defaultAction)
        case .waitingForApproval:
            OnboardingPrimaryButton(title: "Preview approval detected", systemImage: "checkmark") {
                Task { await flow.confirmAccountApproval() }
            }
            .keyboardShortcut(.defaultAction)
        case .confirming:
            OnboardingPrimaryButton(title: "Checking approval…", isWorking: true, isDisabled: true, action: {})
        case .linked:
            OnboardingPrimaryButton(title: "Continue", systemImage: "arrow.right") {
                flow.continueToNextStep()
            }
            .keyboardShortcut(.defaultAction)
        case .expired:
            OnboardingPrimaryButton(title: "Request a new code", systemImage: "arrow.clockwise") {
                flow.retryAccountLink()
            }
            .keyboardShortcut(.defaultAction)
        case .unreachable:
            OnboardingPrimaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                flow.retryAccountLink()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct AccountLinkSurface: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLinked: Bool { flow.accountPhase == .linked }
    private var showsCode: Bool { flow.accountPhase != .introduction && !isLinked }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ACCOUNT LINK")
                    .font(DarkbloomTheme.chivo(9, weight: .medium))
                    .tracking(1.05)
                Spacer()
                Text(statusLabel)
                    .font(DarkbloomTheme.chivo(8, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(isLinked ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.4))
            }

            Spacer()

            LinkEndpoint(
                symbol: "person.crop.circle",
                eyebrow: "YOUR ACCOUNT",
                title: isLinked ? "Connected" : "Approve in browser",
                isComplete: isLinked
            )

            ConnectionTrace(isConnected: isLinked)
                .padding(.leading, 19)

            LinkEndpoint(
                symbol: identity.formFactor.symbolName,
                eyebrow: "THIS MAC",
                title: identity.displayName,
                isComplete: isLinked
            )

            Spacer()

            if showsCode {
                VStack(alignment: .leading, spacing: 5) {
                    Text("8-CHARACTER LINK CODE")
                        .font(DarkbloomTheme.chivo(8, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(flow.accountLinkSession.code)
                                .font(DarkbloomTheme.chivo(21, weight: .medium))
                                .tracking(1.8)
                                .strikethrough(flow.accountPhase == .expired, color: .orange)
                            Text(expiryDetail(at: context.date))
                                .font(DarkbloomTheme.chivo(9))
                                .foregroundStyle(DarkbloomTheme.ink.opacity(0.4))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Link code \(flow.accountLinkSession.code). Expires after 15 minutes.")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Text("Prompts and local files never become part of the account link.")
                    .font(DarkbloomTheme.chivo(10))
                    .lineSpacing(2)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.44))
            }
        }
        .padding(25)
        .frame(width: 350, height: 385, alignment: .topLeading)
        .onboardingPanel()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: flow.accountPhase)
    }

    private var statusLabel: String {
        switch flow.accountPhase {
        case .linked: "CONNECTED"
        case .expired: "EXPIRED"
        case .unreachable: "OFFLINE"
        case .introduction, .waitingForApproval, .confirming: "PRIVATE"
        }
    }

    private func expiryDetail(at date: Date) -> String {
        if flow.accountPhase == .expired || flow.accountLinkSession.isExpired(at: date) {
            return "Expired · this sample code can no longer be approved"
        }
        return "\(flow.accountLinkSession.remainingMinutes(at: date)) minutes remaining · UI preview"
    }
}

private struct LinkEndpoint: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(isComplete ? DarkbloomTheme.accent : DarkbloomTheme.surface)
                .overlay {
                    Image(systemName: isComplete ? "checkmark" : symbol)
                        .font(.system(size: 12, weight: isComplete ? .bold : .regular))
                        .foregroundStyle(isComplete ? .white : DarkbloomTheme.ink)
                }
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(DarkbloomTheme.chivo(8, weight: .medium))
                    .tracking(0.85)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
                Text(title)
                    .font(DarkbloomTheme.chivo(14, weight: .medium))
            }
        }
    }
}

private struct ConnectionTrace: View {
    let isConnected: Bool

    var body: some View {
        Rectangle()
            .fill(isConnected ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.12))
            .frame(width: 1, height: 48)
            .overlay {
                if !isConnected { BreathingStatusDot().frame(width: 17, height: 17) }
            }
    }
}

private extension View {
    func accountStatusStyle(color: Color = DarkbloomTheme.ink.opacity(0.48)) -> some View {
        font(DarkbloomTheme.chivo(11, weight: .medium))
            .foregroundStyle(color)
    }
}
