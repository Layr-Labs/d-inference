import Foundation

struct OnboardingPreviewConfiguration: Equatable, Sendable {
    let step: OnboardingStep
    let variant: String?

    static var current: Self? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment

        if let scenario = environment["DARKBLOOM_PREVIEW_ONBOARDING_STATE"],
           let configuration = scenarioConfiguration(scenario)
        {
            return configuration
        }

        guard
            let value = environment["DARKBLOOM_ONBOARDING_PREVIEW_STEP"],
            let step = OnboardingStep(previewValue: value)
        else {
            return nil
        }

        return Self(
            step: step,
            variant: environment["DARKBLOOM_ONBOARDING_PREVIEW_VARIANT"]
        )
        #else
        return nil
        #endif
    }

    static func scenarioConfiguration(_ scenario: String) -> Self? {
        switch scenario.lowercased() {
        case "check-running": Self(step: .readiness, variant: "working")
        case "check-ready": Self(step: .readiness, variant: "ready")
        case "connect": Self(step: .account, variant: "waiting")
        case "mdm-overview": Self(step: .enrollment, variant: "overview")
        case "mdm-instructions": Self(step: .enrollment, variant: "instructions")
        case "mdm-waiting": Self(step: .enrollment, variant: "waiting")
        case "preparing": Self(step: .preparation, variant: "downloading")
        case "verifying": Self(step: .verification, variant: "working")
        case "ready": Self(step: .complete, variant: "ready")
        default: nil
        }
    }
}
