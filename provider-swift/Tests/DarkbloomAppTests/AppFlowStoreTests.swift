import Testing
@testable import DarkbloomApp

@Suite("App flow")
@MainActor
struct AppFlowStoreTests {
    @Test("A first launch opens on welcome")
    func firstLaunchOpensOnWelcome() {
        let store = AppFlowStore(
            preferences: InMemoryAppFlowPreferences(),
            launchOverride: nil
        )

        #expect(store.phase == .welcome)
        #expect(!store.hasCompletedNetworkOnboarding)
        #expect(store.resumableOnboardingDraft == nil)
    }

    @Test("A configured CLI provider opens the product without replaying onboarding")
    func configuredProviderOpensProduct() {
        let preferences = InMemoryAppFlowPreferences()
        let store = AppFlowStore(
            preferences: preferences,
            launchOverride: nil,
            bootstrapEvidence: AppFlowBootstrapEvidence(
                hasProviderState: true,
                hasVerifiedHardwareTrust: true
            )
        )

        #expect(store.phase == .product)
        #expect(store.hasCompletedNetworkOnboarding)
        #expect(preferences.hasCompletedNetworkOnboarding)
    }

    @Test("Partial machine setup cannot bypass onboarding")
    func partialMachineSetupStaysOnWelcome() {
        let store = AppFlowStore(
            preferences: InMemoryAppFlowPreferences(),
            launchOverride: nil,
            bootstrapEvidence: AppFlowBootstrapEvidence(
                hasProviderState: true,
                hasVerifiedHardwareTrust: false
            )
        )

        #expect(store.phase == .welcome)
        #expect(!store.hasCompletedNetworkOnboarding)
    }

    @Test("A saved onboarding draft wins over machine bootstrap evidence")
    func savedDraftWinsOverMachineBootstrap() {
        let preferences = InMemoryAppFlowPreferences(
            onboardingDraft: OnboardingDraft(
                step: .enrollment,
                readinessCompletedCount: 5,
                accountPhase: .linked,
                enrollmentPhase: .systemSettingsOpen,
                preparationPhase: .reservingSpace,
                preparationProgress: 0.04,
                verificationCompletedCount: 0
            )
        )
        let store = AppFlowStore(
            preferences: preferences,
            launchOverride: nil,
            bootstrapEvidence: AppFlowBootstrapEvidence(
                hasProviderState: true,
                hasVerifiedHardwareTrust: true
            )
        )

        #expect(store.phase == .welcome)
        #expect(!store.hasCompletedNetworkOnboarding)
        #expect(store.resumableOnboardingDraft?.step == .enrollment)
    }

    @Test("A completed setup opens the product shell")
    func completedSetupOpensProduct() {
        let store = AppFlowStore(
            preferences: InMemoryAppFlowPreferences(
                hasCompletedNetworkOnboarding: true
            ),
            launchOverride: nil
        )

        #expect(store.phase == .product)
        #expect(store.selectedDestination == .overview)
        #expect(store.resumableOnboardingDraft == nil)
    }

    @Test("A future onboarding draft is rejected and cleared")
    func futureDraftIsRejected() {
        let preferences = InMemoryAppFlowPreferences(
            onboardingDraft: OnboardingDraft(
                schemaVersion: OnboardingDraft.currentSchemaVersion + 1,
                step: .verification,
                readinessCompletedCount: 6,
                accountPhase: .linked,
                enrollmentPhase: .profileDetected,
                preparationPhase: .ready,
                preparationProgress: 1,
                verificationCompletedCount: 4
            )
        )

        let store = AppFlowStore(preferences: preferences, launchOverride: nil)

        #expect(store.phase == .welcome)
        #expect(store.resumableOnboardingDraft == nil)
        #expect(preferences.onboardingDraft == nil)
        #expect(store.onboardingFlow.step == .readiness)
    }

    @Test("Relaunch preserves interrupted model preparation for reconciliation")
    func relaunchPreservesRequiredPreparation() {
        let savedDraft = OnboardingDraft(
            step: .preparation,
            readinessCompletedCount: 2,
            accountPhase: .introduction,
            enrollmentPhase: .overview,
            preparationPhase: .downloading,
            preparationProgress: 0.58,
            verificationCompletedCount: 0
        )
        let store = AppFlowStore(
            preferences: InMemoryAppFlowPreferences(onboardingDraft: savedDraft),
            launchOverride: nil,
            onboardingFlow: OnboardingFlowModel(freezesAutomaticProgress: true)
        )

        #expect(store.phase == .welcome)
        #expect(store.resumableOnboardingDraft?.step == .preparation)
        #expect(store.resumableOnboardingDraft?.preparationProgress == 0.58)
        #expect(store.resumableOnboardingDraft?.preparationPhase == .downloadFailed)
        #expect(store.onboardingFlow.step == .preparation)
        #expect(store.onboardingFlow.preparationProgress == 0.58)
        #expect(store.onboardingFlow.verificationPhase == .profileDetected)
        #expect(store.onboardingFlow.accountPhase == .introduction)
        #expect(store.onboardingFlow.enrollmentPhase == .overview)
        #expect(store.onboardingFlow.resumeReconciliationState == .required)
        #expect(store.onboardingFlow.isRestoredFromDraft)

        store.resumeOnboarding()
        #expect(store.phase == .onboarding)
        #expect(store.onboardingFlow.step == .preparation)
        #expect(store.onboardingFlow.preparationProgress == 0.58)
        #expect(store.onboardingFlow.resumeReconciliationState == .required)
    }

    @Test("Leaving setup persists and resumes the same screen")
    func onboardingResumesInPlace() {
        let preferences = InMemoryAppFlowPreferences()
        let onboarding = OnboardingFlowModel(
            startingAt: .readiness,
            previewVariant: "ready",
            freezesAutomaticProgress: true
        )
        let store = AppFlowStore(
            preferences: preferences,
            launchOverride: nil,
            onboardingFlow: onboarding
        )

        store.startOnboarding()
        onboarding.continueToNextStep()
        #expect(onboarding.step == .account)
        #expect(preferences.onboardingDraft?.step == .account)

        store.leaveOnboarding()
        #expect(store.phase == .welcome)
        #expect(store.resumableOnboardingDraft?.step == .account)

        store.resumeOnboarding()
        #expect(store.phase == .onboarding)
        #expect(store.onboardingFlow === onboarding)
        #expect(store.onboardingFlow.step == .account)
        #expect(store.onboardingFlow.resumeReconciliationState == .required)
    }

    @Test("Start Over clears prior progress and begins at readiness")
    func startOverClearsPriorProgress() {
        let preferences = InMemoryAppFlowPreferences(
            onboardingDraft: OnboardingDraft(
                step: .enrollment,
                readinessCompletedCount: 5,
                accountPhase: .linked,
                enrollmentPhase: .systemSettingsOpen,
                preparationPhase: .reservingSpace,
                preparationProgress: 0.04,
                verificationCompletedCount: 0
            )
        )
        let store = AppFlowStore(
            preferences: preferences,
            launchOverride: nil,
            onboardingFlow: OnboardingFlowModel(freezesAutomaticProgress: true)
        )

        store.startOverOnboarding()

        #expect(store.phase == .onboarding)
        #expect(store.onboardingFlow.step == .readiness)
        #expect(store.onboardingFlow.readinessCompletedCount == 0)
        #expect(store.onboardingFlow.accountPhase == .introduction)
        #expect(store.onboardingFlow.enrollmentPhase == .overview)
        #expect(!store.onboardingFlow.isRestoredFromDraft)
        #expect(preferences.onboardingDraft?.step == .readiness)
        #expect(preferences.onboardingDraft?.readinessCompletedCount == 0)
    }

    @Test("Completion clears the draft, persists completion, and selects chat")
    func completionPersistsAndClearsDraft() {
        let preferences = InMemoryAppFlowPreferences()
        let completedFlow = OnboardingFlowModel(
            startingAt: .complete,
            previewVariant: "ready",
            freezesAutomaticProgress: true
        )
        let firstStore = AppFlowStore(
            preferences: preferences,
            launchOverride: nil,
            onboardingFlow: completedFlow
        )

        firstStore.startOnboarding()
        #expect(preferences.onboardingDraft?.step == .complete)
        #expect(firstStore.completeOnboarding(opening: .chat))
        #expect(firstStore.phase == .product)
        #expect(firstStore.selectedDestination == .chat)
        #expect(firstStore.pendingInitialProductDestination == .chat)
        firstStore.consumePendingInitialProductDestination()
        #expect(firstStore.pendingInitialProductDestination == nil)
        #expect(firstStore.resumableOnboardingDraft == nil)
        #expect(preferences.hasCompletedNetworkOnboarding)
        #expect(preferences.onboardingDraft == nil)

        let relaunchedStore = AppFlowStore(
            preferences: preferences,
            launchOverride: nil
        )
        #expect(relaunchedStore.phase == .product)
    }

    @Test("Setup cannot be marked complete before its final step")
    func prematureCompletionIsRejected() {
        let preferences = InMemoryAppFlowPreferences()
        let store = AppFlowStore(
            preferences: preferences,
            launchOverride: nil
        )
        store.startOnboarding()

        #expect(!store.completeOnboarding())
        #expect(store.phase == .onboarding)
        #expect(!preferences.hasCompletedNetworkOnboarding)
        #expect(preferences.onboardingDraft != nil)
    }

    @Test("Preview and debug overrides never read or write real progress")
    func launchOverridesArePreferenceIsolated() {
        for override in AppPhase.allCases {
            let preferences = TrackingAppFlowPreferences(
                completion: true,
                draft: sampleEnrollmentDraft
            )
            let store = AppFlowStore(
                preferences: preferences,
                launchOverride: override
            )

            #expect(store.phase == override)
            #expect(preferences.completionReads == 0)
            #expect(preferences.completionWrites == 0)
            #expect(preferences.draftReads == 0)
            #expect(preferences.draftWrites == 0)
            #expect(store.resumableOnboardingDraft == nil)

            store.startOverOnboarding()
            #expect(preferences.completionWrites == 0)
            #expect(preferences.draftWrites == 0)
        }

        let preferences = TrackingAppFlowPreferences(
            completion: false,
            draft: sampleEnrollmentDraft
        )
        let completedFlow = OnboardingFlowModel(
            startingAt: .complete,
            previewVariant: "ready",
            freezesAutomaticProgress: true
        )
        let previewStore = AppFlowStore(
            preferences: preferences,
            launchOverride: .onboarding,
            onboardingFlow: completedFlow
        )

        #expect(previewStore.completeOnboarding(opening: .chat))
        #expect(previewStore.phase == .product)
        #expect(preferences.completionReads == 0)
        #expect(preferences.completionWrites == 0)
        #expect(preferences.draftReads == 0)
        #expect(preferences.draftWrites == 0)
        #expect(!preferences.completionStorage)
        #expect(preferences.draftStorage == sampleEnrollmentDraft)
    }

    @Test("Completion choices map to their intended product destinations")
    func completionChoicesMapToDestinations() {
        #expect(OnboardingCompletionChoice.startChat.destination == .chat)
        #expect(OnboardingCompletionChoice.reviewAvailability.destination == .availability)
    }

    @Test(
        "Debug launch overrides select welcome, onboarding, or product",
        arguments: [
            ("welcome", AppPhase.welcome),
            ("onboarding", AppPhase.onboarding),
            ("product", AppPhase.product),
            ("setup", AppPhase.onboarding),
            ("shell", AppPhase.product),
        ]
    )
    func debugLaunchOverrides(value: String, expected: AppPhase) {
        let override = AppPhase.debugLaunchOverride(
            environment: [AppPhase.debugLaunchEnvironmentKey: value]
        )

        #expect(override == expected)
    }

    @Test("An unknown debug phase is ignored")
    func unknownDebugPhaseIsIgnored() {
        #expect(
            AppPhase.debugLaunchOverride(
                environment: [AppPhase.debugLaunchEnvironmentKey: "unknown"]
            ) == nil
        )
    }

    private var sampleEnrollmentDraft: OnboardingDraft {
        OnboardingDraft(
            step: .enrollment,
            readinessCompletedCount: 5,
            accountPhase: .linked,
            enrollmentPhase: .instructions,
            preparationPhase: .reservingSpace,
            preparationProgress: 0.04,
            verificationCompletedCount: 0
        )
    }
}

@MainActor
private final class TrackingAppFlowPreferences: AppFlowPreferenceStoring {
    private(set) var completionReads = 0
    private(set) var completionWrites = 0
    private(set) var draftReads = 0
    private(set) var draftWrites = 0
    private(set) var completionStorage: Bool
    private(set) var draftStorage: OnboardingDraft?

    init(completion: Bool, draft: OnboardingDraft?) {
        completionStorage = completion
        draftStorage = draft
    }

    var hasCompletedNetworkOnboarding: Bool {
        get {
            completionReads += 1
            return completionStorage
        }
        set {
            completionWrites += 1
            completionStorage = newValue
        }
    }

    var onboardingDraft: OnboardingDraft? {
        get {
            draftReads += 1
            return draftStorage
        }
        set {
            draftWrites += 1
            draftStorage = newValue
        }
    }
}
