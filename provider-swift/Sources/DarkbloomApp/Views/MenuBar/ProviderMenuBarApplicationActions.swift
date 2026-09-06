import SwiftUI

struct ProviderMenuBarApplicationActions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuBarButtonStyle())

                Button("Quit Darkbloom") {
                    DarkbloomApplicationBridge.quitApp()
                }
                .buttonStyle(MenuBarButtonStyle())
                .keyboardShortcut("q")
            }

            Text("Quitting ends local sessions started by this app. The network provider runs independently.")
                .font(DarkbloomTheme.chivo(10.5))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }
}
