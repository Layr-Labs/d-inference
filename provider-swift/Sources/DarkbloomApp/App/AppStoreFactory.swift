/// App-wide ownership of the observable stores injected into all scenes.
@MainActor
struct AppStores {
    let appFlowStore: AppFlowStore
    let providerStore: ProviderStore
    let modelLibraryStore: ModelLibraryStore
    let diagnosticsStore: DiagnosticsStore
    let contributionsStore: ContributionsStore
    let localAPIStore: LocalAPIStore
    let myMacsStore: MyMacsStore
    let availabilityStore: AvailabilityStore
    let accountUnlinkStore: AccountUnlinkStore
    let chatStore: ChatStore
}

/// Resolves dependencies once, keeping preview product services deterministic
/// and live account-session propagation in one place.
@MainActor
enum AppStoreFactory {
    static func make(
        configuration: AppBootstrapConfiguration,
        preferences: (any AppFlowPreferenceStoring)? = nil
    ) -> AppStores {
        let productPreview = configuration.productPreview
        let onboardingPreview = configuration.onboardingPreview
        let isPreviewSession = configuration.isPreviewSession
        let onboardingFlow = OnboardingFlowModel(
            startingAt: onboardingPreview?.step ?? .readiness,
            previewVariant: onboardingPreview?.variant,
            freezesAutomaticProgress: onboardingPreview != nil
        )
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
            let accountSession = AccountSessionManager()
            modelLibraryStore = ModelLibraryStore(live: ProcessModelCatalogCLIRunner())
            diagnosticsStore = DiagnosticsStore(cli: ProcessDiagnosticsCLIRunner())
            contributionsStore = ContributionsStore(cli: ProcessContributionsCLI())
            localAPIStore = LocalAPIStore.live()
            myMacsStore = MyMacsStore(
                session: accountSession,
                fleet: FleetClient(),
                onAccountSessionChange: { isSignedIn in
                    contributionsStore.accountSessionDidChange(isSignedIn: isSignedIn)
                }
            )
            availabilityStore = AvailabilityStore(cli: ProcessAvailabilityCLI())
        }

        let appFlowStore = AppFlowStore(
            preferences: preferences,
            launchOverride: configuration.launchOverride,
            onboardingFlow: onboardingFlow,
            initialDestination: productPreview?.destination ?? .overview,
            bootstrapEvidence: !isPreviewSession
                ? AppFlowBootstrapEvidence(snapshot: providerStore.snapshot)
                : nil
        )
        let accountUnlinkStore = AccountUnlinkStore(
            refreshAfterSuccess: {
                try myMacsStore.signOut()
                await providerStore.refresh()
                await modelLibraryStore.refresh()
                await contributionsStore.refresh()
                await availabilityStore.refresh()
            }
        )
        let chatStore = isPreviewSession
            ? ChatStore(fixture: productPreview?.chatFixture ?? .empty)
            : ChatStore(live: LiveChatConfiguration())
        return AppStores(
            appFlowStore: appFlowStore,
            providerStore: providerStore,
            modelLibraryStore: modelLibraryStore,
            diagnosticsStore: diagnosticsStore,
            contributionsStore: contributionsStore,
            localAPIStore: localAPIStore,
            myMacsStore: myMacsStore,
            availabilityStore: availabilityStore,
            accountUnlinkStore: accountUnlinkStore,
            chatStore: chatStore
        )
    }
}
