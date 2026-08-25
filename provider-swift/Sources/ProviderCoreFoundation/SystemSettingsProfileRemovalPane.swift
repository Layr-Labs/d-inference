import Foundation

/// Canonical macOS deep link for inspecting and removing configuration
/// profiles. Removal still requires explicit user interaction in System
/// Settings.
public enum SystemSettingsProfileRemovalPane {
    public typealias OpenCommand =
        @Sendable ([String]) throws -> Void

    public static let deepLink =
        "x-apple.systempreferences:com.apple.preferences.configurationprofiles"

    public static func open(using command: OpenCommand) {
        try? command([deepLink])
    }
}
