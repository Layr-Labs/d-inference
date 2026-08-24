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

struct AccountUnlinkControl: View {
    let store: AccountUnlinkStore

    @State private var showsConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AccountUnlinkPresentation.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            status

            if store.state != .succeeded {
                Button(buttonTitle, role: .destructive) {
                    showsConfirmation = true
                }
                .disabled(store.state.isUnlinking)
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
        switch store.state {
        case .idle:
            EmptyView()
        case .unlinking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Securely unlinking this Mac…")
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        case .succeeded:
            Label(
                AccountUnlinkPresentation.successMessage,
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(ProductPalette.critical)
        }
    }

    private var buttonTitle: String {
        if case .failed = store.state {
            return "Retry Sign Out & Unlink…"
        }
        return "Sign Out & Unlink This Mac…"
    }
}
