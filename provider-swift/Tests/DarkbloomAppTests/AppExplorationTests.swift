import Testing
@testable import DarkbloomApp

@Suite("Explore before setup")
@MainActor
struct AppExplorationTests {
    @Test("Exploring never persists completion or bypasses setup evidence")
    func explorationIsNotOnboarding() {
        let preferences = InMemoryAppFlowPreferences()
        let store = AppFlowStore(preferences: preferences, launchOverride: nil)

        store.exploreProduct()

        #expect(store.phase == .product)
        #expect(store.isExploring)
        #expect(!store.hasCompletedNetworkOnboarding)
        #expect(!preferences.hasCompletedNetworkOnboarding)
        #expect(!store.completeOnboarding())
        #expect(preferences.onboardingDraft == nil)
        #expect(store.pendingInitialProductDestination == .overview)

        let relaunched = AppFlowStore(preferences: preferences, launchOverride: nil)
        #expect(relaunched.phase == .welcome)
        #expect(!relaunched.hasCompletedNetworkOnboarding)
    }

    @Test("Menu navigation can retarget an open product without completing setup")
    func menuNavigationKeepsSetupBoundary() {
        let preferences = InMemoryAppFlowPreferences()
        let store = AppFlowStore(preferences: preferences, launchOverride: nil)
        store.openProduct(.networkOverview)
        #expect(store.isExploring)
        #expect(store.pendingInitialProductDestination == .networkOverview)
        store.consumePendingInitialProductDestination()
        store.openProduct(.overview)
        #expect(store.pendingInitialProductDestination == .overview)
        #expect(!preferences.hasCompletedNetworkOnboarding)
        #expect(!store.requestNetworkSetup(localSessionIsActive: true))
        #expect(store.isExploring)
        #expect(store.requestNetworkSetup(localSessionIsActive: false))
        #expect(store.phase == .onboarding)
        #expect(!store.hasCompletedNetworkOnboarding)
    }

    @Test("Setup can be resumed from exploration without losing the draft")
    func resumeReturnsToExploration() {
        let preferences = InMemoryAppFlowPreferences()
        let flow = OnboardingFlowModel(
            startingAt: .readiness, previewVariant: "ready", freezesAutomaticProgress: true
        )
        let store = AppFlowStore(preferences: preferences, launchOverride: nil, onboardingFlow: flow)
        store.startOnboarding()
        flow.continueToNextStep()
        #expect(flow.step == .account)
        store.leaveOnboarding()
        let savedDraft = preferences.onboardingDraft

        store.exploreProduct()
        #expect(preferences.onboardingDraft == savedDraft)
        store.resumeOnboarding()
        #expect(flow.step == .account)
        #expect(flow.resumeReconciliationState == .required)
        store.leaveOnboarding()

        #expect(store.isExploring)
        #expect(preferences.onboardingDraft?.step == .account)
        #expect(!preferences.hasCompletedNetworkOnboarding)
    }

    @Test("Only verified runtime evidence can finish bootstrap while exploring")
    func explorationBootstrapRequiresEvidence() {
        let preferences = InMemoryAppFlowPreferences()
        let store = AppFlowStore(preferences: preferences, launchOverride: nil)
        store.exploreProduct()
        store.applyBootstrapEvidence(.init(hasProviderState: true, hasVerifiedHardwareTrust: false))
        #expect(store.isExploring)
        store.applyBootstrapEvidence(.init(hasProviderState: true, hasVerifiedHardwareTrust: true))
        #expect(!store.isExploring)
        #expect(preferences.hasCompletedNetworkOnboarding)
    }

    @Test("Successful unlink makes network setup available without leaving the product")
    func unlinkClearsSetupCompletion() {
        let preferences = InMemoryAppFlowPreferences(hasCompletedNetworkOnboarding: true)
        let store = AppFlowStore(preferences: preferences, launchOverride: nil)
        store.openProduct(.chat)
        store.consumePendingInitialProductDestination()

        store.accountLinkWasRemoved()

        #expect(store.isExploring)
        #expect(store.selectedDestination == .chat)
        #expect(preferences.onboardingDraft == nil)
        #expect(!preferences.hasCompletedNetworkOnboarding)
        let relaunched = AppFlowStore(preferences: preferences, launchOverride: nil)
        #expect(relaunched.phase == .welcome)
        #expect(!relaunched.hasCompletedNetworkOnboarding)
    }
}
