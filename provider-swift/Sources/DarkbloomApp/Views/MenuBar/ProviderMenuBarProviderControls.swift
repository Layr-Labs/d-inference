import SwiftUI

struct ProviderMenuBarProviderControls: View {
    let snapshot: ProviderSnapshot
    let providerStore: ProviderStore
    let localAPIStore: LocalAPIStore
    let allowsRuntimeActions: Bool

    @State private var confirmationAction: ProviderAction?

    private var confirmation: ProviderMenuBarActionConfirmation? {
        confirmationAction.flatMap { ProviderMenuBarActionConfirmation(action: $0, snapshot: snapshot) }
    }

    var body: some View {
        let status = ProviderMenuBarNetworkPresentation(snapshot: snapshot)
        let primaryAction = providerStore.primaryAction

        VStack(alignment: .leading, spacing: 13) {
            MenuBarStatus(
                title: status.title,
                detail: status.detail,
                tone: status.tone,
                isBusy: providerStore.pendingAction != nil || snapshot.runState.isTransitioning
            )

            if localAPIStore.localStart.hasActiveSession {
                Text("End your local session before starting or restarting network sharing.")
                    .font(DarkbloomTheme.chivo(11))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let confirmation {
                inlineConfirmation(confirmation)
            } else if snapshot.runState == .scheduledOff {
                scheduledOffNote
            } else {
                actionButtons(primaryAction: primaryAction)
            }

            if let failure = providerStore.failure {
                failureView(failure)
            }
        }
    }

    private var scheduledOffNote: some View {
        Label {
            Text("Change sharing hours from Availability in Network.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "calendar.badge.clock")
        }
        .font(DarkbloomTheme.chivo(11))
        .foregroundStyle(StudioPalette.secondaryInk)
    }

    private func actionButtons(primaryAction: ProviderAction) -> some View {
        HStack(spacing: 8) {
            Button {
                request(primaryAction)
            } label: {
                Label(ProviderMenuBarActionPresentation.title(primaryAction), systemImage: primaryAction.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuBarButtonStyle(prominent: true))
            .disabled(!canPerform(primaryAction))

            if primaryAction != .restart {
                Button {
                    request(.restart)
                } label: {
                    Text(ProviderMenuBarActionPresentation.title(.restart))
                }
                .buttonStyle(MenuBarButtonStyle())
                .disabled(!canPerform(.restart))
            }
        }
    }

    private func inlineConfirmation(_ confirmation: ProviderMenuBarActionConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(confirmation.title)
                .font(DarkbloomTheme.chivo(12, weight: .medium))
            Text(confirmation.message)
                .font(DarkbloomTheme.chivo(11))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Cancel") {
                    confirmationAction = nil
                }
                .buttonStyle(MenuBarButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(confirmation.buttonTitle, role: .destructive) {
                    confirmationAction = nil
                    perform(confirmation.action)
                }
                .buttonStyle(MenuBarButtonStyle())
                .disabled(!canPerform(confirmation.action))
            }
        }
        .padding(10)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(StudioPalette.line, lineWidth: 1)
        }
    }

    private func failureView(_ failure: ProviderStoreFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ProductPalette.critical)
                Text(failure.message)
                    .font(DarkbloomTheme.chivo(11))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .lineLimit(3)
                    .help(failure.message)
                Spacer(minLength: 4)
            }

            HStack {
                if let action = providerStore.retryableFailureAction {
                    Button("Try network action again") {
                        guard canPerform(action) else { return }
                        providerStore.dismissFailure()
                        request(action)
                    }
                    .disabled(!canPerform(action))
                }

                Button("Dismiss") {
                    providerStore.dismissFailure()
                }
            }
            .buttonStyle(.borderless)
            .font(DarkbloomTheme.chivo(11))
        }
        .padding(9)
        .background(
            ProductPalette.critical.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private func request(_ action: ProviderAction) {
        guard canPerform(action) else { return }
        if ProviderMenuBarActionConfirmation(action: action, snapshot: snapshot) != nil {
            confirmationAction = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: ProviderAction) {
        Task {
            // Re-check after scheduling and confirmation: a local start may
            // have acquired ownership while the popup was open.
            guard canPerform(action) else { return }
            await providerStore.perform(action)
        }
    }

    private func canPerform(_ action: ProviderAction) -> Bool {
        guard allowsRuntimeActions || !action.changesRuntime else { return false }
        guard !ProviderMenuBarActionPresentation.isBlocked(
            action,
            hasActiveLocalSession: localAPIStore.localStart.hasActiveSession
        ) else { return false }
        return providerStore.canPerform(action)
    }
}
