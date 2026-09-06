#if DEBUG
import AppKit
import Testing
@testable import DarkbloomApp

@Suite("Per-launch preview presentation")
@MainActor
struct AppPreviewLaunchConfigurationTests {
    @Test("Preview appearance overrides only this application's appearance")
    func appearanceOverride() {
        let application = NSApplication.shared
        let previous = application.appearance
        defer { application.appearance = previous }

        PreviewAppearance.applyIfRequested(
            to: application, environment: ["DARKBLOOM_PREVIEW_APPEARANCE": "light"]
        )
        #expect(application.appearance?.name == .aqua)
        PreviewAppearance.applyIfRequested(
            to: application, environment: ["DARKBLOOM_PREVIEW_APPEARANCE": "DARK"]
        )
        #expect(application.appearance?.name == .darkAqua)
        PreviewAppearance.applyIfRequested(to: application, environment: [:])
        #expect(application.appearance?.name == .darkAqua)
        PreviewAppearance.applyIfRequested(
            to: application, environment: ["DARKBLOOM_PREVIEW_APPEARANCE": "unknown"]
        )
        #expect(application.appearance?.name == .darkAqua)
    }

    @Test("Preview content dimensions respect the scene minimum")
    func windowDimensions() {
        #expect(resolve(width: "1280", height: "800") == CGSize(width: 1280, height: 800))
        #expect(resolve(width: "800", height: "600") == CGSize(width: 900, height: 620))
    }

    @Test("Missing and invalid dimensions preserve native window restoration")
    func invalidWindowDimensions() {
        #expect(AppBootstrapConfiguration.resolvePreviewWindowSize(environment: [:]) == nil)
        #expect(AppBootstrapConfiguration.resolvePreviewWindowSize(environment: [
            "DARKBLOOM_PREVIEW_WINDOW_WIDTH": "1280",
        ]) == nil)
        for value in ["", "wide", "NaN", "inf", "-1", "0"] {
            #expect(resolve(width: value, height: "800") == nil)
            #expect(resolve(width: "1280", height: value) == nil)
        }
    }

    private func resolve(width: String, height: String) -> CGSize? {
        AppBootstrapConfiguration.resolvePreviewWindowSize(environment: [
            "DARKBLOOM_PREVIEW_WINDOW_WIDTH": width,
            "DARKBLOOM_PREVIEW_WINDOW_HEIGHT": height,
        ])
    }
}
#endif
