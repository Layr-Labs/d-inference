import Foundation

/// Launch inputs only; selecting a launch phase or capture path does not turn
/// live services into fixtures. Only a resolved product/onboarding preview does.
struct AppBootstrapConfiguration {
    let productPreview: ProductPreviewConfiguration?
    let onboardingPreview: OnboardingPreviewConfiguration?
    let debugLaunchOverride: AppPhase?
    let isCapturingPreview: Bool
    let isCapturingLaunchPreview: Bool
    var previewWindowSize: CGSize? = nil

    static var current: Self {
        let environment = ProcessInfo.processInfo.environment
        return Self(
            productPreview: ProductPreviewConfiguration.current,
            onboardingPreview: OnboardingPreviewConfiguration.current,
            debugLaunchOverride: AppPhase.currentDebugLaunchOverride,
            isCapturingPreview: environment["DARKBLOOM_RENDER_PREVIEW_PATH"] != nil,
            isCapturingLaunchPreview: environment["DARKBLOOM_RENDER_LAUNCH_PREVIEW"] == "1",
            previewWindowSize: Self.resolvePreviewWindowSize(environment: environment)
        )
    }

    /// Both dimensions must be finite and positive. Respect the scene minimum
    /// rather than creating a preview that product controls cannot fit inside.
    static func resolvePreviewWindowSize(environment: [String: String]) -> CGSize? {
        #if DEBUG
        guard let width = environment["DARKBLOOM_PREVIEW_WINDOW_WIDTH"].flatMap(Double.init),
              let height = environment["DARKBLOOM_PREVIEW_WINDOW_HEIGHT"].flatMap(Double.init),
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return nil }
        return CGSize(width: max(900, width), height: max(620, height))
        #else
        return nil
        #endif
    }

    var isPreviewSession: Bool {
        productPreview != nil || onboardingPreview != nil
    }

    var launchOverride: AppPhase? {
        productPreview != nil ? .product : (onboardingPreview != nil ? .onboarding : debugLaunchOverride)
    }

    var showsPreviewChrome: Bool {
        PreviewChromePresentation.isVisible(
            hasOnboardingPreview: onboardingPreview != nil,
            hasProductPreview: productPreview != nil
        )
    }
}
