import Foundation

/// Translates Secure Enclave / Keychain `OSStatus` codes into operator advice.
/// Used by the SE-key self-test in `darkbloom doctor` so a signing failure
/// becomes an actionable message instead of a bare negative number.
///
/// Pure (takes an `Int32` rather than the Apple-only `OSStatus` typealias's
/// platform behavior) so it is unit-testable everywhere.
public enum OSStatusCatalog {
    // Well-known Security.framework codes (stable values).
    public static let interactionNotAllowed: Int32 = -25308 // errSecInteractionNotAllowed
    public static let missingEntitlement: Int32 = -34018    // errSecMissingEntitlement
    public static let itemNotFound: Int32 = -25300          // errSecItemNotFound
    public static let duplicateItem: Int32 = -25299         // errSecDuplicateItem
    public static let authFailed: Int32 = -25293            // errSecAuthFailed
    public static let userCanceled: Int32 = -128            // errSecUserCanceled

    public static func advice(osStatus: Int32) -> DiagnosticAdvice {
        switch osStatus {
        case interactionNotAllowed:
            return DiagnosticAdvice(
                message: "the Secure Enclave key exists but cannot sign (OSStatus -25308: keychain locked). The daemon is likely running headless / over SSH, so the login keychain is locked and the key can't answer attestation challenges.",
                fix: "log in at the console once (and stay logged in), then `darkbloom start`. The v2 key uses AfterFirstUnlock, so one post-boot console login is enough.")
        case missingEntitlement:
            return DiagnosticAdvice(
                message: "this binary is missing the keychain-access-groups entitlement (OSStatus -34018), so it cannot use a persistent Secure Enclave key — it will fall back to an ephemeral key and can never reach hardware trust.",
                fix: "reinstall the official signed bundle (re-run the install script); a self-built/unsigned binary cannot attest.")
        case itemNotFound:
            return DiagnosticAdvice(
                message: "no Secure Enclave key found yet (first run, or the key was deleted).",
                fix: "`darkbloom start` will mint one on next launch.")
        case duplicateItem:
            return DiagnosticAdvice(
                message: "a Secure Enclave key already exists under this label (benign race).",
                fix: nil)
        case authFailed:
            return DiagnosticAdvice(
                message: "Secure Enclave signing was denied (OSStatus -25293: authentication failed).",
                fix: "ensure the Mac is unlocked at the console and re-run `darkbloom start`.")
        case userCanceled:
            return DiagnosticAdvice(
                message: "Secure Enclave access was canceled (OSStatus -128).",
                fix: "re-run `darkbloom start` and allow keychain access if prompted.")
        case 0:
            return DiagnosticAdvice(message: "Secure Enclave key signs correctly.", fix: nil)
        default:
            return DiagnosticAdvice(
                message: "Secure Enclave signing failed with OSStatus \(osStatus).",
                fix: "run `darkbloom report` and include this code.")
        }
    }
}
