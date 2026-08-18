import AppKit
import SwiftUI

@main
struct DarkbloomApp: App {
    @NSApplicationDelegateAdaptor(DarkbloomAppDelegate.self) private var appDelegate
    private let isCapturingPreview = ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_PREVIEW_PATH"] != nil
    private let isCapturingLaunchPreview = ProcessInfo.processInfo.environment["DARKBLOOM_RENDER_LAUNCH_PREVIEW"] == "1"
    private let onboardingPreview: OnboardingPreviewConfiguration?
    private let productPreview: ProductPreviewConfiguration?

    @State private var appFlowStore: AppFlowStore
    @State private var providerStore: ProviderStore
    @State private var modelLibraryStore: ModelLibraryStore
    @State private var diagnosticsStore: DiagnosticsStore
    @State private var contributionsStore: ContributionsStore
    @State private var localAPIStore: LocalAPIStore
    @State private var myMacsStore: MyMacsStore
    @State private var availabilityStore: AvailabilityStore

    init() {
        BrandFontLoader.registerFonts()

        let productPreview = ProductPreviewConfiguration.current
        let onboardingPreview = OnboardingPreviewConfiguration.current
        let onboardingFlow = OnboardingFlowModel(
            startingAt: onboardingPreview?.step ?? .readiness,
            previewVariant: onboardingPreview?.variant,
            freezesAutomaticProgress: onboardingPreview != nil
        )

        self.onboardingPreview = onboardingPreview
        self.productPreview = productPreview
        _appFlowStore = State(
            initialValue: AppFlowStore(
                launchOverride: productPreview != nil
                    ? .product
                    : (onboardingPreview != nil ? .onboarding : AppPhase.currentDebugLaunchOverride),
                onboardingFlow: onboardingFlow,
                initialDestination: productPreview?.destination ?? .overview
            )
        )
        // Preview captures stay fully deterministic (fixture service, frozen
        // clock). Real launches track the actual provider daemon: the service
        // polls ~/.darkbloom/daemon-state.json and shells out to the
        // `darkbloom` CLI for start/stop/restart.
        if let productPreview {
            _providerStore = State(
                initialValue: ProviderStore(previewScenario: productPreview.providerScenario)
            )
        } else {
            _providerStore = State(
                initialValue: ProviderStore(daemon: DaemonRuntimeService())
            )
        }
        _modelLibraryStore = State(
            initialValue: ModelLibraryStore(
                fixture: productPreview?.modelFixture ?? .ready
            )
        )
        _diagnosticsStore = State(
            initialValue: DiagnosticsStore(
                fixture: productPreview?.diagnosticsFixture ?? .healthy
            )
        )
        _contributionsStore = State(
            initialValue: ContributionsStore(
                fixture: productPreview?.contributionsFixture ?? .active
            )
        )
        _localAPIStore = State(
            initialValue: LocalAPIStore(
                fixture: productPreview?.localAPIFixture ?? .active
            )
        )
        _myMacsStore = State(
            initialValue: MyMacsStore(
                fixture: productPreview?.myMacsFixture ?? .ready
            )
        )
        _availabilityStore = State(
            initialValue: AvailabilityStore(
                fixture: productPreview?.availabilityFixture ?? .always
            )
        )
    }

    var body: some Scene {
        Window("Darkbloom", id: "main") {
            ContentView(
                showsLaunchExperience: !isCapturingPreview || isCapturingLaunchPreview,
                launchMode: appFlowStore.phase == .product && !isCapturingLaunchPreview
                    ? .ignition
                    : .full,
                onboardingPreview: onboardingPreview,
                productPreview: productPreview,
                appFlowStore: appFlowStore,
                providerStore: providerStore,
                modelLibraryStore: modelLibraryStore,
                diagnosticsStore: diagnosticsStore,
                contributionsStore: contributionsStore,
                localAPIStore: localAPIStore,
                myMacsStore: myMacsStore,
                availabilityStore: availabilityStore
            )
                .background(DarkbloomMainWindowTag())
                .frame(minWidth: 900, minHeight: 620)
                .environment(
                    \.isCapturingDarkbloomPreview,
                    isCapturingPreview && !isCapturingLaunchPreview
                )
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ProviderCommands()
        }

        Settings {
            SettingsRootView(
                appFlowStore: appFlowStore,
                providerStore: providerStore
            )
        }

        MenuBarExtra("Darkbloom", systemImage: "sparkles") {
            ProviderMenuBarView(
                content: ProviderMenuBarContent.resolve(
                    hasCompletedSetup: appFlowStore.hasCompletedNetworkOnboarding,
                    snapshot: providerStore.snapshot
                ),
                providerStore: providerStore
            )
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class DarkbloomAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
        PreviewAppearance.applyIfRequested(to: NSApp)
        #endif
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
