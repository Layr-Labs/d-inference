import Testing
@testable import DarkbloomApp

@Suite("App bootstrap dependency isolation")
@MainActor
struct AppBootstrapTests {
    @Test("The app-owned Chat store survives leaving exploration for setup")
    func chatSurvivesPhaseChanges() {
        let stores = AppStoreFactory.make(configuration: configuration(
            onboarding: .init(step: .readiness, variant: "ready")
        ))
        let chat = stores.chatStore
        #expect(!chat.isLive)
        chat.draft = "An earlier idea"
        chat.reset()
        chat.draft = "An unfinished thought"

        stores.appFlowStore.exploreProduct()
        stores.appFlowStore.startOnboarding()
        stores.appFlowStore.leaveOnboarding()

        #expect(stores.appFlowStore.isExploring)
        #expect(stores.chatStore === chat)
        #expect(stores.chatStore.draft == "An unfinished thought")
        #expect(stores.chatStore.history.first?.draft == "An earlier idea")
    }

    @Test("Every product preview uses fixture product stores without reading or writing onboarding preferences",
          arguments: ProductDestination.allCases)
    func productPreviewIsIsolated(destination: ProductDestination) throws {
        let product = try #require(ProductPreviewConfiguration.resolve(environment: [
            "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": destination.rawValue,
        ]))
        let configuration = self.configuration(product: product)
        let preferences = BootstrapPreferenceProbe()
        let stores = AppStoreFactory.make(configuration: configuration, preferences: preferences)

        expectFixtureProductStores(stores)
        #expect(stores.providerStore.snapshot == product.providerScenario.snapshot)
        #expect(stores.appFlowStore.phase == .product)
        #expect(stores.appFlowStore.selectedDestination == destination)
        #expect(stores.appFlowStore.hasCompletedNetworkOnboarding)
        // Product-only previews historically leave the unused onboarding flow
        // unfrozen; extracting the factory must not change that distinction.
        #expect(!stores.appFlowStore.onboardingFlow.freezesAutomaticProgress)
        #expect(preferences.reads == 0)
        #expect(preferences.writes == 0)
    }

    @Test("Onboarding previews freeze automatic work and use fixture product defaults")
    func onboardingPreviewIsIsolated() {
        let configuration = self.configuration(onboarding: .init(step: .enrollment, variant: "waiting"))
        let preferences = BootstrapPreferenceProbe()
        let stores = AppStoreFactory.make(configuration: configuration, preferences: preferences)

        expectFixtureProductStores(stores)
        #expect(stores.providerStore.snapshot == ProviderPreviewScenario.online.snapshot)
        #expect(stores.appFlowStore.phase == .onboarding)
        #expect(stores.appFlowStore.selectedDestination == .overview)
        #expect(!stores.appFlowStore.hasCompletedNetworkOnboarding)
        #expect(stores.appFlowStore.onboardingFlow.step == .enrollment)
        #expect(stores.appFlowStore.onboardingFlow.freezesAutomaticProgress)
        #expect(!stores.appFlowStore.onboardingFlow.usesLiveEnrollment)
        #expect(preferences.reads == 0)
        #expect(preferences.writes == 0)
    }

    @Test("Product preview wins launch precedence while an onboarding preview still freezes the flow")
    func combinedPreviewsPreservePrecedence() throws {
        let product = try #require(ProductPreviewConfiguration.resolve(environment: [
            "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "availability",
            "DARKBLOOM_PREVIEW_AVAILABILITY_FIXTURE": "scheduled-off",
        ]))
        let configuration = self.configuration(
            product: product,
            onboarding: .init(step: .enrollment, variant: "waiting"),
            debugLaunchOverride: .welcome
        )
        let stores = AppStoreFactory.make(
            configuration: configuration,
            preferences: BootstrapPreferenceProbe()
        )

        #expect(configuration.launchOverride == .product)
        #expect(configuration.showsPreviewChrome)
        #expect(stores.appFlowStore.phase == .product)
        #expect(stores.appFlowStore.selectedDestination == .availability)
        #expect(stores.providerStore.snapshot == ProviderPreviewScenario.scheduledOff.snapshot)
        #expect(stores.appFlowStore.onboardingFlow.freezesAutomaticProgress)
        expectFixtureProductStores(stores)
    }

    @Test("Capture flags and a debug phase alone do not select fixture services")
    func captureAndPhaseAreNotFixtureSelectors() {
        let configuration = AppBootstrapConfiguration(
            productPreview: nil,
            onboardingPreview: nil,
            debugLaunchOverride: .product,
            isCapturingPreview: true,
            isCapturingLaunchPreview: true
        )

        #expect(!configuration.isPreviewSession)
        #expect(!configuration.showsPreviewChrome)
        #expect(configuration.launchOverride == .product)
        #expect(self.configuration().launchOverride == nil)
        #expect(self.configuration(onboarding: .init(step: .readiness, variant: nil),
                                   debugLaunchOverride: .product).launchOverride == .onboarding)
    }

    private func configuration(
        product: ProductPreviewConfiguration? = nil,
        onboarding: OnboardingPreviewConfiguration? = nil,
        debugLaunchOverride: AppPhase? = nil
    ) -> AppBootstrapConfiguration {
        AppBootstrapConfiguration(
            productPreview: product,
            onboardingPreview: onboarding,
            debugLaunchOverride: debugLaunchOverride,
            isCapturingPreview: false,
            isCapturingLaunchPreview: false
        )
    }

    private func expectFixtureProductStores(_ stores: AppStores) {
        #expect(!stores.modelLibraryStore.isLive)
        #expect(!stores.diagnosticsStore.isLive)
        #expect(!stores.contributionsStore.isLive)
        #expect(!stores.localAPIStore.isLive)
        #expect(!stores.availabilityStore.isLive)
        guard case .fixture = stores.myMacsStore.mode else {
            Issue.record("Preview bootstrap created a live account session")
            return
        }
    }
}

@MainActor
private final class BootstrapPreferenceProbe: AppFlowPreferenceStoring {
    private(set) var reads = 0
    private(set) var writes = 0

    var hasCompletedNetworkOnboarding: Bool {
        get { reads += 1; return false }
        set { writes += 1 }
    }

    var onboardingDraft: OnboardingDraft? {
        get { reads += 1; return nil }
        set { writes += 1 }
    }
}
