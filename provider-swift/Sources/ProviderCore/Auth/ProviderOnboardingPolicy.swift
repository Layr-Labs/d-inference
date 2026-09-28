import Foundation

/// Selects setup guidance only. The coordinator still owns serving authorization.
public enum ProviderOnboardingPolicy {
    public static func usesAppAttest(macOSMajorVersion: Int) -> Bool {
        macOSMajorVersion >= 27
    }

    public static let retirementNotice =
        "Darkbloom MDM will be deactivated soon. Upgrade to macOS 27 or later to use App Attest without Darkbloom MDM."

    public static let appAttestGuidance =
        "macOS 27 or later uses App Attest without new Darkbloom MDM enrollment. "
        + "Run `darkbloom login`, then `darkbloom start`, and check `darkbloom status`. "
        + "Serving starts only after the coordinator approves this connection. "
        + "If approval is pending or unavailable, run `darkbloom doctor`; no MDM profile is needed for this setup path. "
        + "Keep existing management profiles installed. To remove an existing Darkbloom profile, "
        + "run `darkbloom unenroll` and choose App Attest once removal is approved."
}
