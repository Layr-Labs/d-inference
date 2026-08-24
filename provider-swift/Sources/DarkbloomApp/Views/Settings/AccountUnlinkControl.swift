import SwiftUI

enum AccountUnlinkPresentation {
    static let explanation =
        "Sign out of this app and unlink this Mac’s provider from your Darkbloom account."
    static let confirmationTitle = "Sign out and unlink this Mac?"
    static let confirmationMessage =
        "Unlike removing a saved My Macs record, this stops the provider, revokes this Mac’s provider token, removes its local link credentials, and signs this app out. It does not delete contribution history, downloaded models, or records for other Macs."
    static let interruptedMessage =
        "Unlinking was interrupted. The app did not clear its account session or refresh account data. The provider may have stopped; retry to let the secure logout finish."
    static let successMessage =
        "This Mac is unlinked and the app is signed out. Contribution history remains on your account."

    static func failureMessage(detail: String) -> String {
        let suffix = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let base =
            "Darkbloom could not confirm that this Mac was unlinked. The app did not clear its account session or refresh account data. If coordinator revocation failed, the secure CLI preserved this Mac’s local credentials so you can retry."
        return suffix.isEmpty ? base : "\(base) \(suffix)"
    }
}

struct AccountUnlinkControlPresentation: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case hidden
        case progress(String)
        case success(String)
        case failure(String)
    }

    let status: Status
    let actionTitle: String?
    let actionDisabled: Bool

    init(state: AccountUnlinkState) {
        switch state {
        case .idle:
            status = .hidden
            actionTitle = "Sign Out & Unlink This Mac…"
            actionDisabled = false
        case .unlinking:
            status = .progress("Securely unlinking this Mac…")
            actionTitle = "Sign Out & Unlink This Mac…"
            actionDisabled = true
        case .succeeded:
            status = .success(AccountUnlinkPresentation.successMessage)
            actionTitle = nil
            actionDisabled = true
        case .failed(let message):
            status = .failure(message)
            actionTitle = "Retry Sign Out & Unlink…"
            actionDisabled = false
        }
    }
}

struct AccountUnlinkControl: View {
    let store: AccountUnlinkStore

    @State private var showsConfirmation = false

    private var presentation: AccountUnlinkControlPresentation {
        AccountUnlinkControlPresentation(state: store.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AccountUnlinkPresentation.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            status

            if let actionTitle = presentation.actionTitle {
                Button(actionTitle, role: .destructive) {
                    showsConfirmation = true
                }
                .disabled(presentation.actionDisabled)
            }
        }
        .confirmationDialog(
            AccountUnlinkPresentation.confirmationTitle,
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out & Unlink This Mac", role: .destructive) {
                Task {
                    await store.unlinkThisMac()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountUnlinkPresentation.confirmationMessage)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch presentation.status {
        case .hidden:
            EmptyView()
        case .progress(let message):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        case .success(let message):
            Label(
                message,
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(ProductPalette.critical)
        }
    }
}
