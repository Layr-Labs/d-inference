import Foundation

/// Canonical filesystem layout shared by the macOS app and launchd services.
/// Paths persisted into launchd must name the real managed executable, never a
/// user-visible shortcut, compatibility symlink, or the currently running app.
public enum ManagedProviderInstallLayout {
    public static let appBundleName = "Darkbloom.app"
    public static let appPathComponents = [".darkbloom", appBundleName]
    public static let helperAppPathComponents = [
        "Contents", "Helpers", "DarkbloomProvider.app",
    ]
    public static let helperExecutablePathComponents = [
        "Contents", "MacOS", "darkbloom",
    ]
    public static let helperAppRelativePath = helperAppPathComponents.joined(separator: "/")
    public static let helperInfoPlistRelativePath =
        helperAppRelativePath + "/Contents/Info.plist"
    public static let helperProvisioningProfileRelativePath =
        helperAppRelativePath + "/Contents/embedded.provisionprofile"
    public static let cliRelativePath =
        (helperAppPathComponents + helperExecutablePathComponents).joined(separator: "/")
    public static let legacyCLIRelativePath = "Contents/MacOS/darkbloom"
    public static let compatibilityCLISymlinkTarget =
        "../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom"
    public static let cliPathComponents =
        appPathComponents + helperAppPathComponents + helperExecutablePathComponents

    /// Pure lexical recognition of the two published CLI layouts. This does
    /// not check existence, resolve symlinks, or establish signing identity.
    /// In particular, the nested provider bundle must never be mistaken for
    /// the outer app by matching only its Contents/MacOS/darkbloom suffix.
    public static func outerAppURL(forExecutableURL executable: URL) -> URL? {
        guard executable.isFileURL else { return nil }
        let lexical = executable.path.split(separator: "/", omittingEmptySubsequences: false)
        guard executable.path.hasPrefix("/"),
              !executable.path.contains("\0"),
              !lexical.contains("."), !lexical.contains("..")
        else { return nil }

        let components = executable.pathComponents
        let nested = helperAppPathComponents + helperExecutablePathComponents
        for suffix in [nested, helperExecutablePathComponents] {
            guard components.count > suffix.count,
                  Array(components.suffix(suffix.count)) == suffix
            else { continue }
            let outerComponents = components.dropLast(suffix.count)
            guard outerComponents.last == appBundleName else { continue }
            // Do not reinterpret a malformed nested app as a legacy outer app.
            guard !outerComponents.dropLast().contains(where: { $0.hasSuffix(".app") }) else {
                return nil
            }
            return suffix.reduce(executable) { url, _ in url.deletingLastPathComponent() }
        }
        return nil
    }

    public static func appURL(homeDirectory: URL) -> URL {
        appPathComponents.reduce(homeDirectory) {
            $0.appendingPathComponent($1)
        }
    }

    public static func cliURL(homeDirectory: URL) -> URL {
        cliURL(appBundleURL: appURL(homeDirectory: homeDirectory))
    }

    public static func cliURL(appBundleURL: URL) -> URL {
        appBundleURL.appendingPathComponent(cliRelativePath)
    }

    public static func legacyCLIURL(homeDirectory: URL) -> URL {
        legacyCLIURL(appBundleURL: appURL(homeDirectory: homeDirectory))
    }

    public static func legacyCLIURL(appBundleURL: URL) -> URL {
        appBundleURL.appendingPathComponent(legacyCLIRelativePath)
    }
}
