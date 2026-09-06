import Observation

@MainActor
@Observable
final class AppFlowStore {
    private(set) var phase: AppPhase
    private(set) var selectedDestination: ProductDestination
    private(set) var hasCompletedNetworkOnboarding: Bool
    private(set) var resumableOnboardingDraft: OnboardingDraft?
    private(set) var pendingInitialProductDestination: ProductDestination?
    private var onboardingReturnPhase: AppPhase = .welcome

    var isExploring: Bool { phase == .product && !hasCompletedNetworkOnboarding }
    var onboardingExitTitle: String {
        onboardingReturnPhase == .product ? "Back to app" : "Back to welcome"
    }

    let onboardingFlow: OnboardingFlowModel

    @ObservationIgnored
    private let preferences: any AppFlowPreferenceStoring

    @ObservationIgnored
    private let persistenceEnabled: Bool

    init(
        preferences: (any AppFlowPreferenceStoring)? = nil,
        launchOverride: AppPhase? = AppPhase.currentDebugLaunchOverride,
        onboardingFlow: OnboardingFlowModel? = nil,
        initialDestination: ProductDestination = .overview,
        bootstrapEvidence: AppFlowBootstrapEvidence? = nil
    ) {
        let preferences = preferences ?? UserDefaultsAppFlowPreferences()
        let persistenceEnabled = launchOverride == nil
        let persistedCompletion = persistenceEnabled
            ? preferences.hasCompletedNetworkOnboarding
            : launchOverride == .product
        let machineCanBootstrap = persistenceEnabled &&
            !persistedCompletion &&
            preferences.onboardingDraft == nil &&
            bootstrapEvidence?.canOpenProductWithoutOnboarding == true
        let hasCompletedOnboarding = persistedCompletion || machineCanBootstrap
        let draftCandidate = persistenceEnabled && !hasCompletedOnboarding
            ? preferences.onboardingDraft
            : nil
        let storedDraft = draftCandidate.flatMap { draft in
            draft.isSupported ? draft.normalizedForResume : nil
        }
        let onboardingFlow = onboardingFlow ?? OnboardingFlowModel()

        if draftCandidate != nil, storedDraft == nil {
            preferences.onboardingDraft = nil
        }
        if machineCanBootstrap {
            preferences.hasCompletedNetworkOnboarding = true
        }

        self.preferences = preferences
        self.persistenceEnabled = persistenceEnabled
        self.onboardingFlow = onboardingFlow
        selectedDestination = initialDestination
        hasCompletedNetworkOnboarding = hasCompletedOnboarding
        resumableOnboardingDraft = storedDraft
        pendingInitialProductDestination = nil
        phase = launchOverride ?? (hasCompletedOnboarding ? .product : .welcome)

        if let storedDraft {
            onboardingFlow.restore(from: storedDraft)
        }

        if persistenceEnabled {
            onboardingFlow.setDraftChangeHandler { [weak self] draft in
                self?.persist(draft: draft)
            }
        }
    }

    func startOnboarding() {
        rememberOnboardingReturnPhase()
        if persistenceEnabled, !hasCompletedNetworkOnboarding {
            persist(draft: onboardingFlow.draft)
        }
        phase = .onboarding
    }

    func resumeOnboarding() {
        rememberOnboardingReturnPhase()
        guard resumableOnboardingDraft != nil else {
            startOnboarding()
            return
        }
        onboardingFlow.requireResumeReconciliation()
        phase = .onboarding
    }

    func startOverOnboarding() {
        rememberOnboardingReturnPhase()
        if persistenceEnabled {
            preferences.onboardingDraft = nil
            resumableOnboardingDraft = nil
        }
        onboardingFlow.resetForNewSetup()
        phase = .onboarding
    }

    func leaveOnboarding() {
        guard phase == .onboarding else { return }
        onboardingFlow.cancelPendingOperations()
        phase = onboardingReturnPhase
    }

    /// Browsing is a navigation choice, never evidence that setup succeeded.
    /// Keep the real stores and resumable draft; do not persist a completion.
    func exploreProduct() {
        onboardingFlow.cancelPendingOperations()
        selectedDestination = .overview
        pendingInitialProductDestination = .overview
        phase = .product
    }

    private func rememberOnboardingReturnPhase() {
        if phase != .onboarding { onboardingReturnPhase = phase }
    }

    func applyBootstrapEvidence(_ evidence: AppFlowBootstrapEvidence) {
        guard persistenceEnabled,
              (phase == .welcome || isExploring),
              !hasCompletedNetworkOnboarding,
              resumableOnboardingDraft == nil,
              evidence.canOpenProductWithoutOnboarding
        else {
            return
        }

        preferences.hasCompletedNetworkOnboarding = true
        hasCompletedNetworkOnboarding = true
        phase = .product
    }

    @discardableResult
    func completeOnboarding(
        opening destination: ProductDestination = .overview
    ) -> Bool {
        guard phase == .onboarding, onboardingFlow.hasCompletedAllRequiredSteps else {
            return false
        }

        if persistenceEnabled {
            preferences.hasCompletedNetworkOnboarding = true
            preferences.onboardingDraft = nil
        }
        hasCompletedNetworkOnboarding = true
        resumableOnboardingDraft = nil
        selectedDestination = destination
        pendingInitialProductDestination = destination
        phase = .product
        return true
    }

    func selectProductDestination(_ destination: ProductDestination) {
        selectedDestination = destination
    }

    /// Consumes the one-shot destination handoff created by setup completion.
    /// Scene restoration owns navigation after the first product shell applies it.
    func consumePendingInitialProductDestination() {
        pendingInitialProductDestination = nil
    }

    private func persist(draft: OnboardingDraft) {
        guard persistenceEnabled, !hasCompletedNetworkOnboarding else { return }
        let draft = draft.normalizedForResume
        preferences.onboardingDraft = draft
        resumableOnboardingDraft = draft
    }
}
