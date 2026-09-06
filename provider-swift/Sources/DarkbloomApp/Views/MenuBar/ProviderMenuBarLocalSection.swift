import SwiftUI

struct ProviderMenuBarLocalSection: View {
    let store: LocalAPIStore
    let showsPreviewChrome: Bool
    let onOpenStudio: () -> Void

    private var presentation: ProviderMenuBarLocalPresentation {
        ProviderMenuBarLocalPresentation(
            state: store.state,
            startState: store.localStart.state,
            hasActiveSession: store.localStart.hasActiveSession,
            isLive: store.isLive && !showsPreviewChrome
        )
    }

    var body: some View {
        let status = presentation

        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                MenuBarSectionHeading(
                    title: "Local AI",
                    detail: "Your chats and API on this Mac.",
                    systemImage: "desktopcomputer"
                )
                Spacer(minLength: 0)
                if status.isSample && !showsPreviewChrome {
                    MenuBarSampleBadge()
                }
            }

            MenuBarStatus(
                title: status.title,
                detail: status.detail,
                tone: status.tone,
                isBusy: status.isBusy
            )

            HStack(spacing: 8) {
                Button(action: onOpenStudio) {
                    MenuBarNavigationLabel(title: "Open Studio", systemImage: "arrow.up.right")
                }
                .buttonStyle(MenuBarButtonStyle(prominent: true))

                if status.showsEndSession {
                    Button("End session") {
                        // Re-check ownership at the action boundary. Never send
                        // provider stop for a discovered/external endpoint.
                        guard presentation.canEndSession else { return }
                        store.localStart.cancel()
                    }
                    .buttonStyle(MenuBarButtonStyle())
                    .disabled(!status.canEndSession)
                    .help("End only the local session started by this app")
                }
            }
        }
    }
}
