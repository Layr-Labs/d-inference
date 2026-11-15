import Foundation

/// Darkbloom verifies Macs with App Attest only; its MDM profile is retired
/// and does nothing. When this install's profile is still installed, `start`,
/// `status` and `doctor` say once how to remove it. Another install's profile
/// and an employer's MDM are never mentioned here.
public enum RetiredMDMProfile {
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
}
