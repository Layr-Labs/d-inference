import Foundation

/// Pure decision for the "enrolled but the coordinator's live MDM check hasn't
/// completed" diagnosis — the silent stall that `darkbloom doctor` used to miss.
///
/// The operative hardware-trust path is the coordinator's LIVE MDM SecurityInfo
/// check, re-earned per connection (the coordinator retries with a bounded
/// backoff — roughly the first retry within a couple minutes, then ~every 15 min
/// — not a fixed 5-min poll). Apple throttles SecurityInfo, so on a flaky/sleeping
/// box that check can keep timing out: the
/// device is genuinely enrolled in Darkbloom MDM, yet the coordinator never
/// upgrades it past `self_signed`, so it stays ONLINE but receives NO traffic.
///
/// The coordinator does NOT emit a distinct "MDM timed out" trust reason — at
/// registration it sends "SE attestation verified, awaiting MDM/ACME upgrade"
/// and stays there. So this state can only be INFERRED locally, by combining
/// the daemon's last trust level (`self_signed`) with this Mac's actual MDM
/// enrollment (`profiles status` says it IS enrolled in Darkbloom). That pair —
/// "we're enrolled, but trust is still self_signed" — is the unresponsive-MDM
/// signature, and it must read differently from "not enrolled at all".
///
/// Pure value logic so it is unit-testable without spawning `profiles` or
/// reading the daemon state file.
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
    /// granted — e.g. via ACME, which needs no MDM profile). The `"hardware"`
    /// short-circuit below is a defensive backstop, not the primary gate.
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
                message: "this Mac IS enrolled in Darkbloom MDM, but the coordinator's live MDM SecurityInfo check hasn't completed — trust is still self_signed, so you're ONLINE but will receive NO traffic until that check passes (this network requires hardware trust). Apple throttles SecurityInfo, so a sleeping or flaky machine can keep this pending.",
                fix: "keep the Mac awake and APNs reachable (don't let it sleep / drop network), then wait a few minutes for the coordinator's next SecurityInfo check (it retries within ~2 min, then about every 15 min). If it's still self_signed after >15 min, open System Settings → General → Device Management (Profiles) and confirm the Darkbloom profile is installed and NOT showing as Pending; if it's pending, approve it, otherwise re-run `darkbloom enroll`.")
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
