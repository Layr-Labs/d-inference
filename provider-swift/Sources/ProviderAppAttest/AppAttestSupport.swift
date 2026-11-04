import CoreServices
import Foundation
@preconcurrency import DeviceCheck

/// Apple's `DCAppAttestService.isSupported`, plus the one repair the provider
/// can make itself. DeviceCheck also checks macOS LaunchServices' record of the
/// running app. A self-update swaps `Darkbloom.app` in place, and that record
/// can keep describing the previous bundle for minutes to hours. Meanwhile Apple
/// answers unsupported (`is_supported_false`) in every process, including one
/// that launchd restarts. Re-registering the bundle, which is what
/// `lsregister -f` does, brings the record up to date.
struct AppAttestSupport: Sendable {
    let isSupported: @Sendable () -> Bool
    /// Registers the app bundle at the URL again. Best effort: asking Apple
    /// again afterwards is the only check of whether it helped.
    let refreshRegistration: @Sendable (URL) -> Void

    static let system = AppAttestSupport(
        isSupported: { DCAppAttestService.shared.isSupported },
        refreshRegistration: { LaunchServicesRegistration.refresh($0) })
}

public enum LaunchServicesRegistration {
    /// `LSRegisterURL(app, true)`: registers the bundle again even when
    /// LaunchServices already has a record for it. Returns the `OSStatus`.
    @discardableResult
    public static func refresh(_ app: URL) -> Int32 {
        LSRegisterURL(app as CFURL, true)
    }
}
