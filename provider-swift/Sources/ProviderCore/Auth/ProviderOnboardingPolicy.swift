import Foundation

/// Selects setup guidance only. The coordinator still owns serving authorization.
public enum ProviderOnboardingPolicy {
    public static func usesAppAttest(macOSMajorVersion: Int) -> Bool {
        macOSMajorVersion >= 27
    }

    /// Darkbloom verifies a Mac only with App Attest.
    public static let appAttestRequirement =
        "Darkbloom verifies Macs with App Attest only, which needs macOS 27 or later."

    public static let appAttestGuidance =
        "Run `\(BuildEnvironment.current.cliName) login`, then `\(BuildEnvironment.current.cliName) start`, and check `\(BuildEnvironment.current.cliName) status`. "
        + "Serving starts once the coordinator authorizes this connection with App Attest; no profile is needed. "
        + "If authorization stays pending, run `\(BuildEnvironment.current.cliName) doctor`."

    /// For a Mac below macOS 27, which cannot use App Attest.
    public static let upgradeGuidance =
        "Update to macOS 27 or later (System Settings → General → Software Update), then run `\(BuildEnvironment.current.cliName) restart`."
}
