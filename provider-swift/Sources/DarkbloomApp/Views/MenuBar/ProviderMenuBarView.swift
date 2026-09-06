import SwiftUI

struct ProviderMenuBarView: View {
    let content: ProviderMenuBarContent
    let providerStore: ProviderStore
    let localAPIStore: LocalAPIStore
    let showsPreviewChrome: Bool
    let onOpenStudio: () -> Void
    let onOpenNetwork: () -> Void
    let onContinueSetup: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(18)

            MenuBarRule()

            ProviderMenuBarLocalSection(
                store: localAPIStore,
                showsPreviewChrome: showsPreviewChrome,
                onOpenStudio: { open(onOpenStudio) }
            )
            .padding(18)

            MenuBarRule()

            networkSection
                .padding(18)

            MenuBarRule()

            ProviderMenuBarApplicationActions()
                .padding(12)
        }
        .frame(width: 350)
        .font(DarkbloomTheme.chivo(12))
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
        .background(StudioPalette.canvas)
        .task {
            guard !showsPreviewChrome else { return }
            // The app owns the shared monitors. The popup only refreshes their
            // observations; closing it must not stop either monitor.
            async let localRefresh: Void = localAPIStore.refreshNow(forceProbe: true)
            async let providerRefresh: Void = providerStore.refresh()
            _ = await (localRefresh, providerRefresh)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(StudioPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(StudioPalette.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                Text("Darkbloom")
                    .font(DarkbloomTheme.chivo(21, weight: .medium))
                    .tracking(-0.65)

                Spacer(minLength: 0)

                if showsPreviewChrome {
                    MenuBarSampleBadge()
                }
            }

            if showsPreviewChrome {
                MenuBarPreviewDisclosure()
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            MenuBarSectionHeading(
                title: "Darkbloom network",
                detail: "Macs sharing compute for private AI.",
                systemImage: "network"
            )

            switch content {
            case .setup:
                ProviderMenuBarSetupView(
                    hasActiveLocalSession: localAPIStore.localStart.hasActiveSession,
                    onContinue: { open(onContinueSetup) }
                )
            case .provider(let snapshot):
                ProviderMenuBarProviderControls(
                    snapshot: snapshot,
                    providerStore: providerStore,
                    localAPIStore: localAPIStore,
                    allowsRuntimeActions: !showsPreviewChrome
                )
            }

            Button {
                open(onOpenNetwork)
            } label: {
                MenuBarNavigationLabel(title: "Open Network", systemImage: "arrow.up.right")
            }
            .buttonStyle(MenuBarButtonStyle())
        }
    }

    private func open(_ route: () -> Void) {
        route()
        openMainWindow()
    }

    private func openMainWindow() {
        DarkbloomApplicationBridge.openOrActivateMainWindow(using: openWindow)
    }
}
