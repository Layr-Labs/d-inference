import AppKit
import SwiftUI

@main
struct DarkbloomApp: App {
    @NSApplicationDelegateAdaptor(DarkbloomAppDelegate.self) private var appDelegate
    private let configuration: AppBootstrapConfiguration

    // The app owns one stable set of observable stores, shared by every scene.
    @State private var stores: AppStores

    private var installPresentation: AppInstallScenePresentation {
        AppInstallScenePresentation(installState: appDelegate.installState)
    }

    init() {
        BrandFontLoader.registerFonts()
        let configuration = AppBootstrapConfiguration.current
        self.configuration = configuration
        _stores = State(initialValue: AppStoreFactory.make(configuration: configuration))
    }

    var body: some Scene {
        Window("Darkbloom", id: "main") {
            Group {
                switch installPresentation.mainContent {
                case .product:
                    ContentView(
                        showsLaunchExperience: !configuration.isCapturingPreview || configuration.isCapturingLaunchPreview,
                        launchMode: stores.appFlowStore.phase == .product && !configuration.isCapturingLaunchPreview
                            ? .ignition
                            : .full,
                        onboardingPreview: configuration.onboardingPreview,
                        productPreview: configuration.productPreview,
                        appFlowStore: stores.appFlowStore,
                        providerStore: stores.providerStore,
                        modelLibraryStore: stores.modelLibraryStore,
                        diagnosticsStore: stores.diagnosticsStore,
                        contributionsStore: stores.contributionsStore,
                        localAPIStore: stores.localAPIStore,
                        myMacsStore: stores.myMacsStore,
                        availabilityStore: stores.availabilityStore,
                        chatStore: stores.chatStore
                    )
                    .background(DarkbloomMainWindowTag())
                    .environment(
                        \.isCapturingDarkbloomPreview,
                        configuration.isCapturingPreview && !configuration.isCapturingLaunchPreview
                    )
                case .failure(let failure):
                    AppInstallationFailureView(failure: failure)
                case .handingOff:
                    AppInstallationProgressView(message: "Opening the installed app...")
                case .recovery(let recovery):
                    AppInstallationRecoveryView(recovery: recovery)
                }
            }
            .frame(minWidth: 900, minHeight: 620)
            .onAppear {
                appDelegate.prepareForTermination = {
                    await stores.localAPIStore.prepareForApplicationTermination()
                }
            }
            .background {
                #if DEBUG
                AppPreviewWindowSizing(size: configuration.previewWindowSize)
                #endif
            }
        }
        .defaultSize(
            width: configuration.previewWindowSize?.width ?? 1040,
            height: configuration.previewWindowSize?.height ?? 680
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            if installPresentation.showsProviderCommands {
                ProviderCommands()
            }
        }

        Settings {
            if installPresentation.showsProductSettings {
                SettingsRootView(
                    providerStore: stores.providerStore,
                    accountUnlinkStore: stores.accountUnlinkStore,
                    showsPreviewControls: configuration.showsPreviewChrome
                )
            } else {
                Text("Finish installing Darkbloom before changing settings.")
                    .padding(24)
            }
        }

        MenuBarExtra("Darkbloom", systemImage: "sparkles") {
            if installPresentation.showsProviderMenuControls {
                ProviderMenuBarView(
                    content: ProviderMenuBarContent.resolve(
                        hasCompletedSetup: stores.appFlowStore.hasCompletedNetworkOnboarding,
                        snapshot: stores.providerStore.snapshot
                    ),
                    providerStore: stores.providerStore,
                    showsPreviewChrome: configuration.showsPreviewChrome
                )
            } else {
                Button("Quit Darkbloom") {
                    NSApp.terminate(nil)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
