import Foundation

@MainActor
protocol AppFlowPreferenceStoring: AnyObject {
    var hasCompletedNetworkOnboarding: Bool { get set }
    var onboardingDraft: OnboardingDraft? { get set }
}

@MainActor
final class UserDefaultsAppFlowPreferences: AppFlowPreferenceStoring {
    private let defaults: UserDefaults
    private let completionKey: String
    private let draftKey: String

    init(
        defaults: UserDefaults = .standard,
        completionKey: String = "darkbloom.app-flow.network-onboarding-complete",
        draftKey: String = "darkbloom.app-flow.onboarding-draft"
    ) {
        self.defaults = defaults
        self.completionKey = completionKey
        self.draftKey = draftKey
    }

    var hasCompletedNetworkOnboarding: Bool {
        get { defaults.bool(forKey: completionKey) }
        set { defaults.set(newValue, forKey: completionKey) }
    }

    var onboardingDraft: OnboardingDraft? {
        get {
            guard let data = defaults.data(forKey: draftKey),
                  let draft = try? JSONDecoder().decode(OnboardingDraft.self, from: data),
                  draft.isSupported
            else {
                return nil
            }
            return draft.normalizedForResume
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue.normalizedForResume)
            else {
                defaults.removeObject(forKey: draftKey)
                return
            }
            defaults.set(data, forKey: draftKey)
        }
    }
}

@MainActor
final class InMemoryAppFlowPreferences: AppFlowPreferenceStoring {
    var hasCompletedNetworkOnboarding: Bool
    var onboardingDraft: OnboardingDraft?

    init(
        hasCompletedNetworkOnboarding: Bool = false,
        onboardingDraft: OnboardingDraft? = nil
    ) {
        self.hasCompletedNetworkOnboarding = hasCompletedNetworkOnboarding
        self.onboardingDraft = onboardingDraft
    }
}
