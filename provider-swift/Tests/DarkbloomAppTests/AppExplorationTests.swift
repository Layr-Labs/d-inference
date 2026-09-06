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
}
