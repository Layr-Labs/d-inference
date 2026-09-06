import SwiftUI

struct ProviderMenuBarSetupView: View {
    let hasActiveLocalSession: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarStatus(
                title: "Network setup required",
                detail: hasActiveLocalSession
                    ? "End your local session before setting up this Mac to share compute."
                    : "Set up this Mac to share compute. Local AI works independently.",
                tone: .neutral
            )

            Button(action: onContinue) {
                MenuBarNavigationLabel(title: "Set up network sharing", systemImage: "arrow.right")
            }
            .buttonStyle(MenuBarButtonStyle(prominent: true))
            .disabled(hasActiveLocalSession)
        }
    }
}
