import Foundation

/// Enrollment and trust are separate: a managed Mac may still be waiting for
/// SecurityInfo, Apple posture or process identity verification. Local enrollment
/// does not establish which remote step is pending.
public enum MDMTrustDiagnosis {
    /// Decide the MDM-enrollment trust diagnostic for the operator, given the
    /// daemon's last-known coordinator trust level and this Mac's MDM enrollment
    /// state.
    ///
    /// - Parameters:
    ///   - trustLevel: the coordinator's last reported trust level for this box.
    ///     The coordinator only ever emits `"none"`, `"self_signed"`, or
    ///     `"hardware"` (mda_verified is a separate boolean *proof*, never a trust
    ///     level) — nil when the daemon hasn't received a trust status yet.
    ///   - status: the coordinator's last reported status (`"online"`,
    ///     `"untrusted"`, …) — nil when unknown. The MDM-pending hint only applies
    ///     to a provider that is actually `online`.
    ///   - enrollment: this Mac's MDM enrollment state from `checkMDMEnrollment`.
    /// - Returns: a `.trust` diagnostic to surface, or nil when no MDM-enrollment
    ///   hint is warranted (e.g. already enrolled AND hardware-trusted, where the
    ///   trust line above already says "earning").
    ///
    /// Callers should only invoke this when the box is NOT already
    /// hardware-trusted (the enrollment hint is pointless once hardware trust is
    /// granted). The `"hardware"` short-circuit below is a defensive backstop,
    /// not the primary gate.
    public static func diagnose(
        trustLevel: String?,
        status: String?,
        enrollment: MDMEnrollmentState
    ) -> Diagnostic? {
        // Defensive: a hardware-trusted box never needs an enrollment nag, even
        // if a caller forgets to gate on it.
        if trustLevel == "hardware" {
            return nil
        }

        switch enrollment {
        case .enrolledDarkbloom:
            // Enrolled in OUR MDM but trust is still self_signed ⇒ the
            // coordinator's live MDM SecurityInfo check hasn't completed. This is
            // the case that previously printed nothing, leaving the operator to
            // think doctor "passed" while they silently earn nothing.
            //
            // Only flag it when we KNOW trust is self_signed AND the provider is
            // online. A nil trustLevel means the daemon is stopped/stale; a
            // self_signed/untrusted provider has a different (challenge-failure)
            // problem the trust-status line already covers. In both cases the
            // "you're ONLINE but earning nothing, just waiting on MDM" message
            // would be wrong and point at the wrong fix.
            guard trustLevel == "self_signed", status == "online" else { return nil }
            return Diagnostic(
                section: .trust, name: "mdm verification", level: .warn,
                message: "this Mac IS enrolled in Darkbloom MDM, but SecurityInfo, Apple posture or process identity verification is still pending. Trust remains self_signed: you're ONLINE but receive NO traffic until verification completes.",
                fix: "keep the provider running, the Mac awake and APNs reachable. Check that the Darkbloom profile is approved rather than Pending. Verification retries automatically; fresh Apple attestations are rate limited, so repeated restarts or re-enrollment will not speed it up.")

        case .enrolledOtherMDM(let serverURL):
            return Diagnostic(
                section: .trust, name: "mdm enrollment", level: .warn,
                message: "this Mac is managed by another MDM (\(serverURL)) — macOS allows one MDM per device, so Darkbloom hardware trust can't be granted here.",
                fix: "remove that profile in System Settings → Device Management (if it's yours to remove), then run `darkbloom enroll`.")
        case .notEnrolled:
            return Diagnostic(
                section: .trust, name: "mdm enrollment", level: .warn,
                message: "this Mac is not enrolled in MDM — hardware trust can't be granted, so you won't receive traffic on a hardware-trust network.",
                fix: "run `darkbloom enroll` and approve the profile in System Settings → Profiles, then wait ~5 min.")
        case .checkFailed:
            // Unknown state — asserting "not enrolled" here would send an
            // enrolled operator down the wrong flow, so stay silent (the
            // coordinator-doctor check reports the tool failure separately).
            return nil
        }
    }
}
