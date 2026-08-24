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
    @State private var accountUnlinkStore: AccountUnlinkStore

    private var showsPreviewChrome: Bool {
        PreviewChromePresentation.isVisible(
            hasOnboardingPreview: onboardingPreview != nil,
            hasProductPreview: productPreview != nil
        )
    }

    init() {
        BrandFontLoader.registerFonts()

        let productPreview = ProductPreviewConfiguration.current
        let onboardingPreview = OnboardingPreviewConfiguration.current
        let isPreviewSession = productPreview != nil || onboardingPreview != nil
        let onboardingFlow = OnboardingFlowModel(
            startingAt: onboardingPreview?.step ?? .readiness,
            previewVariant: onboardingPreview?.variant,
            freezesAutomaticProgress: onboardingPreview != nil
        )

        self.onboardingPreview = onboardingPreview
        self.productPreview = productPreview
        let providerStore = isPreviewSession
            ? ProviderStore(
                previewScenario: productPreview?.providerScenario ?? .online
            )
            : ProviderStore(daemon: DaemonRuntimeService())
        let modelLibraryStore: ModelLibraryStore
        let diagnosticsStore: DiagnosticsStore
        let contributionsStore: ContributionsStore
        let localAPIStore: LocalAPIStore
        let myMacsStore: MyMacsStore
        let availabilityStore: AvailabilityStore

        // Preview captures stay fully deterministic (fixture services, frozen
        // clock). Real launches wire every product store to its live source:
        // ProviderStore polls ~/.darkbloom/daemon-state.json and shells out
        // to the `darkbloom` CLI for lifecycle; the model library drives the
        // CLI's models commands; diagnostics run `doctor --json`;
        // availability persists via `config set schedule`; contributions read
        // `earnings --json`; the local API probes ~/.darkbloom/local.json;
        // My Macs uses the coordinator-backed account session.
        if isPreviewSession {
            modelLibraryStore = ModelLibraryStore(
                fixture: productPreview?.modelFixture ?? .ready
            )
            diagnosticsStore = DiagnosticsStore(
                fixture: productPreview?.diagnosticsFixture ?? .healthy
            )
            contributionsStore = ContributionsStore(
                fixture: productPreview?.contributionsFixture ?? .active
            )
            localAPIStore = LocalAPIStore(
                fixture: productPreview?.localAPIFixture ?? .active
            )
            myMacsStore = MyMacsStore(
                fixture: productPreview?.myMacsFixture ?? .ready
            )
            availabilityStore = AvailabilityStore(
                fixture: productPreview?.availabilityFixture ?? .always
            )
        } else {
            modelLibraryStore = ModelLibraryStore(live: ProcessModelCatalogCLIRunner())
            diagnosticsStore = DiagnosticsStore(cli: ProcessDiagnosticsCLIRunner())
            contributionsStore = ContributionsStore(cli: ProcessContributionsCLI())
            localAPIStore = LocalAPIStore.live()
            myMacsStore = MyMacsStore(
                session: AccountSessionManager(),
                fleet: FleetClient()
            )
            availabilityStore = AvailabilityStore(cli: ProcessAvailabilityCLI())
        }

        _appFlowStore = State(
            initialValue: AppFlowStore(
                launchOverride: productPreview != nil
                    ? .product
                    : (onboardingPreview != nil ? .onboarding : AppPhase.currentDebugLaunchOverride),
                onboardingFlow: onboardingFlow,
                initialDestination: productPreview?.destination ?? .overview,
                bootstrapEvidence: !isPreviewSession
                    ? AppFlowBootstrapEvidence(snapshot: providerStore.snapshot)
                    : nil
            )
        )
        _providerStore = State(initialValue: providerStore)
        _modelLibraryStore = State(initialValue: modelLibraryStore)
        _diagnosticsStore = State(initialValue: diagnosticsStore)
        _contributionsStore = State(initialValue: contributionsStore)
        _localAPIStore = State(initialValue: localAPIStore)
        _myMacsStore = State(initialValue: myMacsStore)
        _availabilityStore = State(initialValue: availabilityStore)
        _accountUnlinkStore = State(initialValue: AccountUnlinkStore(
            refreshAfterSuccess: {
                myMacsStore.signOut()
                async let providerRefresh: Void = providerStore.refresh()
                async let modelRefresh: Void = modelLibraryStore.refresh()
                async let contributionsRefresh: Void = contributionsStore.refresh()
                async let availabilityRefresh: Void = availabilityStore.refresh()
                _ = await (
                    providerRefresh,
                    modelRefresh,
                    contributionsRefresh,
                    availabilityRefresh
                )
            }
        ))
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
                    providerStore: providerStore,
                    accountUnlinkStore: accountUnlinkStore,
                    showsPreviewControls: showsPreviewChrome
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
                    providerStore: providerStore,
                    showsPreviewChrome: showsPreviewChrome
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
final class DarkbloomAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var installState: AppInstallLaunchState

    override init() {
        let coordinator = AppInstallCoordinator()
        installState = Self.resolveInstallState(
            destinationURL: coordinator.destinationURL,
            coordinate: coordinator.coordinate
        )
        super.init()
    }

    init(
        destinationURL: URL,
        coordinate: () throws -> AppInstallOutcome
    ) {
        installState = Self.resolveInstallState(
            destinationURL: destinationURL,
            coordinate: coordinate
        )
        super.init()
    }

    func applicationWillFinishLaunching(_: Notification) {
        guard case .handingOff = installState else {
            return
        }
        NSApp.terminate(nil)
    }

    private static func resolveInstallState(
        destinationURL: URL,
        coordinate: () throws -> AppInstallOutcome
    ) -> AppInstallLaunchState {
        do {
            switch try coordinate() {
            case .continueLaunch:
                return .ready
            case .relocated:
                return .handingOff
            }
        } catch {
            return .failed(AppInstallationFailure(
                error: error,
                destination: destinationURL
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

enum AppInstallLaunchState {
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
        case .handingOff:
            false
        }
    }
}

struct AppInstallationFailure {
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
