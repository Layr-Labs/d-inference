import Foundation

/// Cleanup help for Macs that still carry the old Darkbloom MDM profile.
/// Darkbloom verifies Macs with App Attest only and runs no MDM; the profile
/// does nothing. When this install's profile is still installed, `start`,
/// `status` and `doctor` say once how to remove it, and `unenroll` (choice 2)
/// opens System Settings at it. Another install's profile and an employer's
/// MDM are never mentioned here. Nothing here needs privileges or removes a
/// profile: macOS lets only the user remove one.
public enum RetiredMDMProfile {
    /// The name the Darkbloom enrollment profile was installed under.
    public static let displayName = "Darkbloom Provider Enrollment"

    public static let removalStep =
        "run `\(BuildEnvironment.current.cliName) unenroll` and choose 2; System Settings opens at the profile, then click Remove"

    /// One line for `start` and `status`; nil unless this install's profile is installed.
    public static func notice(for state: MDMEnrollmentState) -> String? {
        guard state.isDarkbloom else { return nil }
        return "The Darkbloom MDM profile on this Mac is no longer used (Darkbloom verifies Macs with App Attest). "
            + "To remove it, \(removalStep)."
    }

    public static func diagnostic(for state: MDMEnrollmentState) -> Diagnostic? {
        guard state.isDarkbloom else { return nil }
        return Diagnostic(
            section: .trust, name: "darkbloom mdm profile", level: .info,
            message: "the Darkbloom MDM profile is still installed but no longer used: Darkbloom verifies Macs with App Attest only.",
            fix: removalStep + ". Keep any profile from your employer or school.")
    }

    /// Opens System Settings at the installed profiles.
    public static func openSystemSettings() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["x-apple.systempreferences:com.apple.preferences.configurationprofiles"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let childExit = ProcessExitObserver()
        guard (try? childExit.run(process)) != nil else { return }
        childExit.wait()
    }
}
