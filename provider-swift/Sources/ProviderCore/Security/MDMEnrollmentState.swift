/// MDM enrollment state of this Mac, as reported by
/// `profiles status -type enrollment` — the authoritative, current source.
///
/// Darkbloom vs foreign matters because macOS allows exactly ONE MDM
/// enrollment per device: a Mac managed by a corporate MDM cannot enroll in
/// Darkbloom's MicroMDM, and an unenrolled Mac must never be told it is
/// "already enrolled" (the pre-0.6.2 heuristics did exactly that from stale
/// profile residue, locking providers out of re-enrollment).
public enum MDMEnrollmentState: Equatable, Sendable {
    case notEnrolled
    case enrolledDarkbloom(serverURL: String)
    case enrolledOtherMDM(serverURL: String)
    /// `profiles status` could not be run (or produced no output) — the state
    /// is UNKNOWN, which is distinct from "not enrolled": unenroll must not
    /// tell an enrolled user there is nothing to remove, and doctor must not
    /// assert non-enrollment, just because the tool transiently failed.
    case checkFailed

    public var isDarkbloom: Bool {
        if case .enrolledDarkbloom = self { return true }
        return false
    }
}
