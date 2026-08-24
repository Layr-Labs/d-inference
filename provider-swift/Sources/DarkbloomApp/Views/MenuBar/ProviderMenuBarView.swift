import SwiftUI

struct ProviderMenuBarView: View {
    let content: ProviderMenuBarContent
    let providerStore: ProviderStore
    let showsPreviewChrome: Bool

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Group {
                switch content {
                case .setup:
                    ProviderMenuBarSetupView(onContinue: openMainWindow)
                case .provider(let snapshot):
                    ProviderMenuBarProviderControls(
                        snapshot: snapshot,
                        providerStore: providerStore
                    )
                }
            }
            .padding(14)

            Divider()

            applicationActions
                .padding(10)
        }
        .frame(width: 326)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Darkbloom")
                    .font(DarkbloomTheme.chivo(18))
                    .tracking(-0.45)

                Spacer()

                if showsPreviewChrome {
                    Text("PREVIEW")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(DarkbloomTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(DarkbloomTheme.accent.opacity(0.09), in: Capsule())
                }
            }

            if showsPreviewChrome {
                MenuBarPreviewDisclosure()
            }
        }
        .padding(14)
    }

    private var applicationActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openMainWindow()
            } label: {
                utilityRow("Open Darkbloom…", systemImage: "macwindow")
            }
            .buttonStyle(.plain)

            SettingsLink {
                utilityRow("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 4)

            Button {
                DarkbloomApplicationBridge.quitApp()
            } label: {
                utilityRow("Quit Darkbloom App", systemImage: "power")
            }
            .buttonStyle(.plain)

            Text("Quitting the app does not stop the provider or take this Mac offline.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 7)
                .padding(.top, 2)
        }
    }

    private func utilityRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer()
        }
        .font(.system(size: 12.5, weight: .medium))
        .contentShape(Rectangle())
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    private func openMainWindow() {
        DarkbloomApplicationBridge.openOrActivateMainWindow(using: openWindow)
    }
}
