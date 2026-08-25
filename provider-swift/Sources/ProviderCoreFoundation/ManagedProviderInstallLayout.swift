import Foundation

/// Canonical filesystem layout shared by the macOS app and launchd services.
///
/// The app bundle under `~/.darkbloom` is the managed, replaceable install.
/// User-visible shortcuts and the `bin` directory may contain symlinks, so
/// neither is suitable for a path persisted into a LaunchAgent plist.
public enum ManagedProviderInstallLayout {
    public static let cliPathComponents = [
        ".darkbloom",
        "Darkbloom.app",
        "Contents",
        "MacOS",
        "darkbloom",
    ]

    public static func cliURL(homeDirectory: URL) -> URL {
        cliPathComponents.reduce(homeDirectory.standardizedFileURL) {
            $0.appendingPathComponent($1)
        }
    }
}
