import AppKit
import Combine
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
        // Preview captures stay fully deterministic (fixture services, frozen
        // clock). Real launches wire every product store to its live source:
        // ProviderStore polls ~/.darkbloom/daemon-state.json and shells out
        // to the `darkbloom` CLI for lifecycle; the model library drives the
        // CLI's models commands; diagnostics run `doctor --json`;
        // availability persists via `config set schedule`; contributions read
        // `earnings --json`; the local API probes ~/.darkbloom/local.json;
        // My Macs uses the coordinator-backed account session.
        if let productPreview {
            _providerStore = State(
                initialValue: ProviderStore(previewScenario: productPreview.providerScenario)
            )
            _modelLibraryStore = State(
                initialValue: ModelLibraryStore(fixture: productPreview.modelFixture)
            )
            _diagnosticsStore = State(
                initialValue: DiagnosticsStore(fixture: productPreview.diagnosticsFixture)
            )
            _contributionsStore = State(
                initialValue: ContributionsStore(fixture: productPreview.contributionsFixture)
            )
            _localAPIStore = State(
                initialValue: LocalAPIStore(fixture: productPreview.localAPIFixture)
            )
            _myMacsStore = State(
                initialValue: MyMacsStore(fixture: productPreview.myMacsFixture)
            )
            _availabilityStore = State(
                initialValue: AvailabilityStore(fixture: productPreview.availabilityFixture)
            )
        } else {
            _providerStore = State(
                initialValue: ProviderStore(daemon: DaemonRuntimeService())
            )
            _modelLibraryStore = State(
                initialValue: ModelLibraryStore(live: ProcessModelCatalogCLIRunner())
            )
            _diagnosticsStore = State(
                initialValue: DiagnosticsStore(cli: ProcessDiagnosticsCLIRunner())
            )
            _contributionsStore = State(
                initialValue: ContributionsStore(cli: ProcessContributionsCLI())
            )
            _localAPIStore = State(initialValue: LocalAPIStore.live())
            _myMacsStore = State(
                initialValue: MyMacsStore(
                    session: AccountSessionManager(),
                    fleet: FleetClient()
                )
            )
            _availabilityStore = State(
                initialValue: AvailabilityStore(cli: ProcessAvailabilityCLI())
            )
        }
    }

    var body: some Scene {
        Window("Darkbloom", id: "main") {
            Group {
                switch appDelegate.installState {
                case .ready:
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
                    .environment(
                        \.isCapturingDarkbloomPreview,
                        isCapturingPreview && !isCapturingLaunchPreview
                    )
                case .failed(let failure):
                    AppInstallationFailureView(failure: failure)
                case .checking:
                    AppInstallationProgressView(message: "Preparing Darkbloom...")
                case .handingOff:
                    AppInstallationProgressView(message: "Opening the installed app...")
                }
            }
            .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            if appDelegate.installState.isReady {
                ProviderCommands()
            }
        }

        Settings {
            if appDelegate.installState.isReady {
                SettingsRootView(
                    appFlowStore: appFlowStore,
                    providerStore: providerStore
                )
            } else {
                Text("Finish installing Darkbloom before changing settings.")
                    .padding(24)
            }
        }

        MenuBarExtra("Darkbloom", systemImage: "sparkles") {
            if appDelegate.installState.isReady {
                ProviderMenuBarView(
                    content: ProviderMenuBarContent.resolve(
                        hasCompletedSetup: appFlowStore.hasCompletedNetworkOnboarding,
                        snapshot: providerStore.snapshot
                    ),
                    providerStore: providerStore
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

@MainActor
final class DarkbloomAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published fileprivate var installState = AppInstallLaunchState.checking

    func applicationWillFinishLaunching(_: Notification) {
        let coordinator = AppInstallCoordinator()
        do {
            switch try coordinator.coordinate() {
            case .continueLaunch:
                installState = .ready
            case .relocated:
                installState = .handingOff
                NSApp.terminate(nil)
            }
        } catch {
            installState = .failed(AppInstallationFailure(
                error: error,
                destination: coordinator.destinationURL
            ))
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
        PreviewAppearance.applyIfRequested(to: NSApp)
        #endif
        guard installState.isInteractive else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum AppInstallLaunchState {
    case checking
    case ready
    case handingOff
    case failed(AppInstallationFailure)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isInteractive: Bool {
        switch self {
        case .ready, .failed:
            true
        case .checking, .handingOff:
            false
        }
    }
}

private struct AppInstallationFailure {
    let message: String
    let recoverySuggestion: String
    let destination: URL

    init(error: any Error, destination: URL) {
        let localized = error as? any LocalizedError
        message = localized?.errorDescription
            ?? (error as NSError).localizedDescription
        recoverySuggestion = localized?.recoverySuggestion
            ?? "Check that ~/.darkbloom and your home Applications folder are writable, then reopen Darkbloom."
        self.destination = destination
    }
}

private struct AppInstallationProgressView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
        }
    }
}

private struct AppInstallationFailureView: View {
    let failure: AppInstallationFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Darkbloom could not install itself")
                .font(.title2.bold())
            Text(failure.message)
            Text(failure.recoverySuggestion)
                .foregroundStyle(.secondary)
            Text("Install location: \(failure.destination.path)")
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack {
                Button("Show Install Folder") {
                    NSWorkspace.shared.open(failure.destination.deletingLastPathComponent())
                }
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(48)
    }
}
