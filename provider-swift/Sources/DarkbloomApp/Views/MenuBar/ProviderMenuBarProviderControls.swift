import SwiftUI

struct ProviderMenuBarProviderControls: View {
    let snapshot: ProviderSnapshot
    let providerStore: ProviderStore

    @State private var confirmation: ProviderActionConfirmation?

    var body: some View {
        let status = snapshot.statusPresentation
        let primaryAction = providerStore.primaryAction

        VStack(alignment: .leading, spacing: 13) {
            statusHeader(status)

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
        .task {
            providerStore.startMonitoring()
        }
    }

    private var scheduledOffNote: some View {
        Label {
            Text("Darkbloom will reconnect when the next availability window begins. Change the plan from Availability in the app.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "calendar.badge.clock")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusHeader(_ status: ProviderStatusPresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.sidebarTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(status.sidebarDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if providerStore.pendingAction != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Provider action in progress")
            }
        }
    }

    private func actionButtons(primaryAction: ProviderAction) -> some View {
        HStack(spacing: 8) {
            Button {
                request(primaryAction)
            } label: {
                Label(primaryAction.title, systemImage: primaryAction.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!providerStore.canPerform(primaryAction))

            if primaryAction != .restart {
                Button {
                    request(.restart)
                } label: {
                    Label("Restart", systemImage: ProviderAction.restart.systemImage)
                }
                .buttonStyle(.bordered)
                .disabled(!providerStore.canPerform(.restart))
            }
        }
    }

    private func inlineConfirmation(_ confirmation: ProviderActionConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(confirmation.title)
                .font(.system(size: 12, weight: .semibold))
            Text(confirmation.message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Cancel") {
                    self.confirmation = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(confirmation.buttonTitle, role: .destructive) {
                    self.confirmation = nil
                    perform(confirmation.action)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func failureView(_ failure: ProviderStoreFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ProductPalette.critical)
                Text(failure.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }

            HStack {
                if providerStore.retryableFailureAction != nil {
                    Button("Try Again") {
                        Task {
                            await providerStore.retryFailure()
                        }
                    }
                }

                Button("Dismiss") {
                    providerStore.dismissFailure()
                }
            }
        }
        .padding(9)
        .background(
            ProductPalette.critical.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private func request(_ action: ProviderAction) {
        if let confirmation = ProviderActionConfirmation(action: action, snapshot: snapshot) {
            self.confirmation = confirmation
        } else {
            perform(action)
        }
    }

    private func perform(_ action: ProviderAction) {
        Task {
            await providerStore.perform(action)
        }
    }
}
